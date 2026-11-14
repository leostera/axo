#include "bridge.h"
#include <mlx/mlx.h>
#include <mlx/backend/metal/metal.h>
#include <nlohmann/json.hpp>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>

namespace mx = mlx::core;
namespace fs = std::filesystem;
using Json = nlohmann::json;
namespace {
constexpr int kMaxTokens = 4096;
constexpr size_t kMaxJsonBytes = 1024 * 1024;
std::string metallib_path;
std::mutex initialization;
void require(bool condition, const std::string& message) {
  if (!condition) throw std::invalid_argument(message);
}
Json read_config(const fs::path& path) {
  require(fs::file_size(path) <= kMaxJsonBytes, "config.json exceeds 1 MiB");
  std::ifstream file(path);
  require(bool(file), "cannot open config.json");
  return Json::parse(file);
}
int dimension(const Json& config, const char* key, int maximum) {
  require(config.at(key).is_number_integer(), std::string("expected integer dimension: ") + key);
  auto value = config.at(key).get<int64_t>();
  require(value > 0 && value <= maximum, std::string("invalid dimension: ") + key);
  return static_cast<int>(value);
}
struct Config {
  std::string architecture;
  int hidden, intermediate, layers, heads, kv_heads, head_dim, vocab, context;
  float epsilon, theta;
  bool tied;
  int group = 64, bits = 4;
  bool quantized = false;

  explicit Config(const Json& j) {
    architecture = j.at("model_type").get<std::string>();
    require(architecture == "qwen2" || architecture == "qwen3",
            "unsupported model_type: " + architecture + "; supported: qwen2, qwen3 dense");
    hidden = dimension(j, "hidden_size", 32768);
    intermediate = dimension(j, "intermediate_size", 131072);
    layers = dimension(j, "num_hidden_layers", 256);
    heads = dimension(j, "num_attention_heads", 256);
    kv_heads = dimension(j, "num_key_value_heads", 256);
    vocab = dimension(j, "vocab_size", 1048576);
    context = dimension(j, "max_position_embeddings", 16777216);
    head_dim = j.contains("head_dim") ? dimension(j, "head_dim", 1024) : hidden / heads;
    if (j.contains("architectures")) {
      require(j["architectures"] == Json::array({architecture == "qwen2" ? "Qwen2ForCausalLM" : "Qwen3ForCausalLM"}),
              "only native causal-language-model heads are supported");
    }
    require(head_dim > 0 && head_dim <= 1024 && head_dim % 2 == 0,
            "head_dim must be positive, even, <= 1024");
    require(heads % kv_heads == 0, "attention heads must be divisible by KV heads");
    require(hidden % heads == 0 || j.contains("head_dim"), "hidden_size is not divisible by heads");
    epsilon = j.value("rms_norm_eps", 1e-6f);
    theta = j.value("rope_theta", 10000.f);
    require(std::isfinite(epsilon) && epsilon > 0 && std::isfinite(theta) && theta > 0,
            "invalid RMS epsilon or RoPE theta");
    tied = j.value("tie_word_embeddings", false);
    require(j.value("hidden_act", std::string("silu")) == "silu", "only SiLU activation supported");
    require(!j.contains("rope_scaling") || j["rope_scaling"].is_null(), "RoPE scaling unsupported");
    require(!j.value("use_sliding_window", false), "sliding-window attention unsupported");
    require(!j.contains("num_experts") && !j.contains("num_local_experts"), "MoE unsupported");
    require(!j.value("attention_bias", architecture == "qwen2") || architecture == "qwen2",
            "Qwen3 attention_bias unsupported");
    if (j.contains("layer_types")) {
      for (const auto& type : j["layer_types"])
        require(type == "full_attention", "only full_attention layers supported");
    }
    if (j.contains("quantization") && j.contains("quantization_config"))
      require(j["quantization"] == j["quantization_config"], "conflicting quantization configuration");
    auto q = j.find("quantization");
    if (q == j.end()) q = j.find("quantization_config");
    if (q != j.end() && !q->is_null()) {
      require(q->value("quant_method", std::string("affine")) == "affine" &&
              q->value("mode", std::string("affine")) == "affine",
              "only MLX affine quantization supported (not GPTQ/AWQ/bitsandbytes)");
      group = q->contains("group_size") ? dimension(*q, "group_size", 128) : 64;
      bits = q->contains("bits") ? dimension(*q, "bits", 8) : 4;
      require(group == 32 || group == 64 || group == 128, "unsupported affine group_size");
      require(bits == 2 || bits == 4 || bits == 8, "unsupported affine bits");
      // Per-module overrides need their own dimensions and cannot be silently ignored.
      for (auto it = q->begin(); it != q->end(); ++it)
        require(!it.value().is_object(), "per-module quantization overrides unsupported");
      quantized = true;
    }
  }
};

class Model {
 public:
  Config config;
  std::unordered_map<std::string, mx::array> weights;
  mutable std::unordered_set<std::string> used_weights;
  explicit Model(const fs::path& directory) : config(read_config(directory / "config.json")) {
    {
      std::lock_guard<std::mutex> lock(initialization);
      require(!metallib_path.empty(), "initialize the packaged MLX Metal resource before loading a model");
    }
    size_t shards = 0;
    for (const auto& entry : fs::directory_iterator(directory)) {
      if (entry.path().extension() != ".safetensors") continue;
      require(entry.is_regular_file() && !entry.is_symlink(), "model shards must be regular, non-symlink files");
      require(++shards <= 128, "too many safetensors shards");
      auto loaded = mx::load_safetensors(entry.path().string()).first;
      for (auto& pair : loaded)
        require(weights.emplace(pair.first, std::move(pair.second)).second,
                "duplicate tensor: " + pair.first);
    }
    require(shards > 0, "no .safetensors weights in model directory");
    validate_weights();
    for (const auto& [name, _] : weights)
      require(used_weights.count(name) != 0, "unsupported extra tensor/head: " + name);
  }
  const mx::array& weight(const std::string& name) const {
    auto it = weights.find(name);
    require(it != weights.end(), "missing tensor: " + name);
    used_weights.insert(name);
    return it->second;
  }
  void shape(const std::string& name, const mx::Shape& expected) const {
    const auto& w = weight(name);
    require(w.shape() == expected, "invalid tensor shape: " + name);
    require(w.dtype() == mx::float32 || w.dtype() == mx::float16 || w.dtype() == mx::bfloat16,
            "expected floating tensor: " + name);
  }
  bool packed(const std::string& name) const {
    return weights.count(name + ".scales") != 0;
  }
  void matrix(const std::string& name, int output, int input) const {
    if (!packed(name)) {
      shape(name + ".weight", {output, input});
      return;
    }
    require(config.quantized, "packed weights require affine quantization config");
    require(input % config.group == 0 && input % (32 / config.bits) == 0,
            "packed matrix dimension not divisible by quantization group");
    const auto& w = weight(name + ".weight");
    require(w.dtype() == mx::uint32 && w.shape() == mx::Shape{output, input / (32 / config.bits)},
            "invalid packed weight: " + name);
    shape(name + ".scales", {output, input / config.group});
    shape(name + ".biases", {output, input / config.group});
  }
  void validate_weights() const {
    const auto& c = config;
    matrix("model.embed_tokens", c.vocab, c.hidden);
    shape("model.norm.weight", {c.hidden});
    if (!c.tied) matrix("lm_head", c.vocab, c.hidden);
    for (int layer = 0; layer < c.layers; ++layer) {
      const auto p = "model.layers." + std::to_string(layer) + ".";
      shape(p + "input_layernorm.weight", {c.hidden});
      shape(p + "post_attention_layernorm.weight", {c.hidden});
      matrix(p + "self_attn.q_proj", c.heads * c.head_dim, c.hidden);
      matrix(p + "self_attn.k_proj", c.kv_heads * c.head_dim, c.hidden);
      matrix(p + "self_attn.v_proj", c.kv_heads * c.head_dim, c.hidden);
      matrix(p + "self_attn.o_proj", c.hidden, c.heads * c.head_dim);
      matrix(p + "mlp.gate_proj", c.intermediate, c.hidden);
      matrix(p + "mlp.up_proj", c.intermediate, c.hidden);
      matrix(p + "mlp.down_proj", c.hidden, c.intermediate);
      if (c.architecture == "qwen2") {
        shape(p + "self_attn.q_proj.bias", {c.heads * c.head_dim});
        shape(p + "self_attn.k_proj.bias", {c.kv_heads * c.head_dim});
        shape(p + "self_attn.v_proj.bias", {c.kv_heads * c.head_dim});
      } else {
        shape(p + "self_attn.q_norm.weight", {c.head_dim});
        shape(p + "self_attn.k_norm.weight", {c.head_dim});
      }
    }
  }
  mx::array linear(const mx::array& x, const std::string& name) const {
    auto result = packed(name)
        ? mx::quantized_matmul(x, weight(name + ".weight"), weight(name + ".scales"),
                               weight(name + ".biases"), true, config.group, config.bits)
        : mx::matmul(x, mx::transpose(weight(name + ".weight")));
    auto bias = weights.find(name + ".bias");
    return bias == weights.end() ? result : mx::add(result, bias->second);
  }
  mx::array embed(const mx::array& ids) const {
    const std::string name = "model.embed_tokens";
    if (!packed(name)) return mx::take(weight(name + ".weight"), ids, 0);
    // Dequantize only requested rows, not the entire vocabulary matrix.
    return mx::dequantize(mx::take(weight(name + ".weight"), ids, 0),
                         mx::take(weight(name + ".scales"), ids, 0),
                         mx::take(weight(name + ".biases"), ids, 0), config.group, config.bits);
  }
  mx::array attention(const mx::array& x, const std::string& p, int length) const {
    const auto& c = config;
    auto q = mx::reshape(linear(x, p + "q_proj"), {1, length, c.heads, c.head_dim});
    auto k = mx::reshape(linear(x, p + "k_proj"), {1, length, c.kv_heads, c.head_dim});
    auto v = mx::reshape(linear(x, p + "v_proj"), {1, length, c.kv_heads, c.head_dim});
    if (c.architecture == "qwen3") {
      q = mx::fast::rms_norm(q, weight(p + "q_norm.weight"), c.epsilon);
      k = mx::fast::rms_norm(k, weight(p + "k_norm.weight"), c.epsilon);
    }
    q = mx::fast::rope(mx::transpose(q, {0, 2, 1, 3}), c.head_dim, false, c.theta, 1.f, 0);
    k = mx::fast::rope(mx::transpose(k, {0, 2, 1, 3}), c.head_dim, false, c.theta, 1.f, 0);
    v = mx::transpose(v, {0, 2, 1, 3});
    auto attended = mx::fast::scaled_dot_product_attention(q, k, v,
        1.f / std::sqrt(float(c.head_dim)), "causal");
    return linear(mx::reshape(mx::transpose(attended, {0, 2, 1, 3}),
                              {1, length, c.heads * c.head_dim}), p + "o_proj");
  }
  Json predict(const Json& inputs) const {
    require(inputs.is_object() && inputs.size() == 1 && inputs.contains("input_ids"),
            "expected exactly one named input: input_ids");
    const auto& tensor = inputs.at("input_ids");
    require(tensor.at("type") == "tensor" && tensor.at("dtype") == "int32",
            "input_ids must be a tagged int32 tensor");
    const auto& dims = tensor.at("shape");
    require(dims.is_array() && (dims.size() == 1 || dims.size() == 2), "input_ids rank must be 1 or 2");
    if (dims.size() == 2) require(dims[0] == 1, "only batch size 1 supported");
    auto length64 = dims.back().get<int64_t>();
    require(length64 > 0 && length64 <= std::min(kMaxTokens, config.context), "input token count exceeds limit");
    int length = static_cast<int>(length64);
    const auto& data = tensor.at("data");
    require(data.is_array() && data.size() == size_t(length), "input_ids data/shape mismatch");
    std::vector<int32_t> tokens;
    tokens.reserve(length);
    for (const auto& token : data) {
      require(token.is_number_integer(), "token IDs must be integers");
      auto id = token.get<int64_t>();
      require(id >= 0 && id < config.vocab, "token ID outside vocabulary");
      tokens.push_back(static_cast<int32_t>(id));
    }
    auto x = mx::reshape(embed(mx::array(tokens.data(), {length}, mx::int32)), {1, length, config.hidden});
    for (int layer = 0; layer < config.layers; ++layer) {
      auto p = "model.layers." + std::to_string(layer) + ".";
      auto normalized = mx::fast::rms_norm(x, weight(p + "input_layernorm.weight"), config.epsilon);
      x = mx::add(x, attention(normalized, p + "self_attn.", length));
      normalized = mx::fast::rms_norm(x, weight(p + "post_attention_layernorm.weight"), config.epsilon);
      auto gate = linear(normalized, p + "mlp.gate_proj");
      auto silu = mx::multiply(gate, mx::sigmoid(gate));
      x = mx::add(x, linear(mx::multiply(silu, linear(normalized, p + "mlp.up_proj")), p + "mlp.down_proj"));
      // Bound the lazy graph to one layer rather than retaining all intermediates.
      mx::eval(x);
    }
    x = mx::fast::rms_norm(mx::slice(x, {0, length - 1, 0}, {1, length, config.hidden}),
                           weight("model.norm.weight"), config.epsilon);
    auto logits = linear(x, config.tied ? "model.embed_tokens" : "lm_head");
    require(mx::all(mx::isfinite(logits)).item<bool>(), "model produced non-finite logits");
    auto token = mx::argmax(mx::reshape(logits, {config.vocab}));
    return Json{{"next_token", {{"type", "int"}, {"value", token.item<uint32_t>()}}}};
  }
  Json description() const {
    return Json{{"backend", "mlx"}, {"runtime_version", "0.32.4"},
                {"model_type", config.architecture}, {"task", "generate"},
                {"max_input_tokens", std::min(kMaxTokens, config.context)},
                {"vocab_size", config.vocab}, {"batch_size", 1},
                {"quantization", config.quantized ? "affine" : "none"},
                {"inputs", {{"input_ids", {{"type", "tensor"}, {"dtype", "int32"}}}}},
                {"outputs", {{"next_token", {{"type", "int"}}}}},
                {"kv_cache", false}};
  }
};

char* copy_string(const std::string& value) {
  auto* result = new char[value.size() + 1];
  std::memcpy(result, value.c_str(), value.size() + 1);
  return result;
}
// All exception categories, including allocation failures, stop at the C ABI.
template<class F> auto protect(char** error, F action) noexcept -> decltype(action()) {
  if (error) *error = nullptr;
  try { return action(); }
  catch (const std::exception& e) {
    if (error) { try { *error = copy_string(e.what()); } catch (...) {} }
  } catch (...) {
    if (error) { try { *error = copy_string("unknown native MLX exception"); } catch (...) {} }
  }
  return nullptr;
}
Model& checked(void* model) {
  require(model != nullptr, "null MLX model");
  return *static_cast<Model*>(model);
}
}  // namespace
extern "C" int axo_mlx_initialize(const char* path, char** error) {
  if (error) *error = nullptr;
  auto* result = protect(error, [&]() -> void* {
    require(path != nullptr && fs::path(path).is_absolute() && fs::is_regular_file(path),
            "MLX requires an absolute path to the packaged Metal library");
    const auto selected = fs::canonical(path).string();
    std::lock_guard<std::mutex> lock(initialization);
    if (metallib_path == selected) return reinterpret_cast<void*>(1);
    require(metallib_path.empty() || metallib_path == selected,
            "the MLX resource cannot be reconfigured after initialization");
    mx::metal::set_metallib_path(selected);
    mx::set_default_device(mx::Device(mx::Device::gpu));
    // Force real Metal initialization now, before publishing a ready runtime.
    auto probe = mx::add(mx::array(1.f), mx::array(1.f));
    require(probe.item<float>() == 2.f, "MLX device initialization failed");
    metallib_path = selected;
    return reinterpret_cast<void*>(1);
  });
  return result == nullptr ? 0 : 1;
}
extern "C" void* axo_mlx_load(const char* directory, char** error) {
  return protect(error, [&]() -> void* {
    require(directory != nullptr, "null model directory");
    return new Model(fs::path(directory));
  });
}
extern "C" char* axo_mlx_description(void* model, char** error) {
  return protect(error, [&] { return copy_string(checked(model).description().dump()); });
}
extern "C" char* axo_mlx_predict(void* model, const char* inputs, char** error) {
  return protect(error, [&] {
    require(inputs != nullptr, "null prediction input");
    require(strnlen(inputs, kMaxJsonBytes + 1) <= kMaxJsonBytes, "prediction input exceeds 1 MiB");
    return copy_string(checked(model).predict(Json::parse(inputs)).dump());
  });
}
extern "C" void axo_mlx_free(void* model) {
  // Model owns only RAII arrays; destruction must not propagate across the ABI.
  try { delete static_cast<Model*>(model); } catch (...) {}
}
extern "C" void axo_mlx_string_free(char* text) { delete[] text; }
