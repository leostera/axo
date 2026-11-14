#include "bridge.h"
#include <mlx/mlx.h>
#include <nlohmann/json.hpp>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <unistd.h>

namespace mx = mlx::core;
namespace fs = std::filesystem;
using Json = nlohmann::json;
void check(bool condition, const char* diagnostic) {
  if (!condition) throw std::runtime_error(diagnostic);
}
struct TemporaryDirectory {
  fs::path path;
  TemporaryDirectory() {
    std::string pattern = (fs::temp_directory_path() / "axo-mlx-test-XXXXXX").string();
    auto* directory = mkdtemp(pattern.data());
    check(directory != nullptr, "mkdtemp failed");
    path = directory;
  }
  ~TemporaryDirectory() { std::error_code ignored; fs::remove_all(path, ignored); }
};
void tensor_calculations() {
  auto x = mx::array({1.f, 2.f, 3.f, 4.f}, {2, 2});
  auto y = mx::matmul(x, x);
  mx::eval(y);
  check(y.data<float>()[0] == 7.f && y.data<float>()[3] == 22.f, "MLX matmul mismatch");
  auto rms = mx::fast::rms_norm(mx::array({3.f, 4.f}), std::nullopt, 0.f);
  mx::eval(rms);
  check(std::abs(rms.data<float>()[0] - 3.f / std::sqrt(12.5f)) < 1e-5f, "RMS norm mismatch");
  auto q = mx::zeros({1, 1, 2, 2});
  auto v = mx::array({2.f, 4.f, 6.f, 8.f}, {1, 1, 2, 2});
  auto attention = mx::fast::scaled_dot_product_attention(q, q, v, 1.f, "causal");
  mx::eval(attention);
  check(std::abs(attention.data<float>()[0] - 2.f) < 1e-5f &&
        std::abs(attention.data<float>()[2] - 4.f) < 1e-5f, "causal attention mismatch");
}

void fixture(const fs::path& directory, const std::string& architecture, bool quantized, bool changed_head, int bits = 4, int group = 32) {
  const int hidden = 128;
  Json config = {{"model_type", architecture}, {"hidden_size", hidden},
    {"intermediate_size", hidden}, {"num_hidden_layers", 1}, {"num_attention_heads", 4},
    {"num_key_value_heads", 4}, {"vocab_size", 3}, {"max_position_embeddings", 16},
    {"rms_norm_eps", 1e-6}, {"tie_word_embeddings", false}};
  if (quantized) config["quantization"] = {{"group_size", group}, {"bits", bits}};
  std::ofstream(directory / "config.json") << config.dump();
  std::unordered_map<std::string, mx::array> weights;
  auto matrix = [&](const std::string& name, const mx::array& value) {
    if (quantized) {
      auto quantized = mx::quantize(value, group, bits);
      check(quantized.size() == 3, "affine quantization did not return weights/scales/biases");
      weights.emplace(name + ".weight", quantized[0]);
      weights.emplace(name + ".scales", quantized[1]);
      weights.emplace(name + ".biases", quantized[2]);
    } else weights.emplace(name + ".weight", value);
  };
  std::vector<float> embedding(3 * hidden, 0.f);
  embedding[0] = 1.f;
  embedding[hidden + 1] = 1.f;
  embedding[2 * hidden] = embedding[2 * hidden + 1] = 1.f;
  matrix("model.embed_tokens", mx::array(embedding.data(), {3, hidden}));
  weights.emplace("model.norm.weight", mx::ones({hidden}));
  std::vector<float> head(3 * hidden, 0.f);
  head[0] = changed_head ? 100.f : 1.f;
  head[hidden + 1] = 1.f;
  head[2 * hidden + 1] = 2.f;
  matrix("lm_head", mx::array(head.data(), {3, hidden}));
  std::string p = "model.layers.0.";
  weights.emplace(p + "input_layernorm.weight", mx::ones({hidden}));
  weights.emplace(p + "post_attention_layernorm.weight", mx::ones({hidden}));
  matrix(p + "self_attn.q_proj", mx::zeros({hidden, hidden}));
  matrix(p + "self_attn.k_proj", mx::zeros({hidden, hidden}));
  matrix(p + "self_attn.v_proj", mx::eye(hidden));
  matrix(p + "self_attn.o_proj", mx::eye(hidden));
  for (const auto* name : {"gate_proj", "up_proj", "down_proj"})
    matrix(p + "mlp." + name, mx::zeros({hidden, hidden}));
  if (architecture == "qwen2") {
    for (const auto* name : {"q_proj", "k_proj", "v_proj"})
      weights.emplace(p + "self_attn." + name + ".bias", mx::zeros({hidden}));
  } else {
    weights.emplace(p + "self_attn.q_norm.weight", mx::ones({hidden / 4}));
    weights.emplace(p + "self_attn.k_norm.weight", mx::ones({hidden / 4}));
  }
  mx::save_safetensors((directory / "model.safetensors").string(), weights);
}
Json input() {
  return {{"input_ids", {{"type", "tensor"}, {"dtype", "int32"},
                        {"shape", {1, 2}}, {"data", {0, 1}}}}};
}
void model_test(const std::string& architecture, bool quantized, bool changed_head, int bits = 4, int group = 32) {
  TemporaryDirectory directory;
  fixture(directory.path, architecture, quantized, changed_head, bits, group);
  char* error = nullptr;
  void* model = axo_mlx_load(directory.path.c_str(), &error);
  std::string diagnostic = error ? error : "";
  axo_mlx_string_free(error);
  check(model != nullptr, diagnostic.c_str());
  char* description = axo_mlx_description(model, &error);
  check(description != nullptr && error == nullptr, "description failed");
  check(Json::parse(description)["model_type"] == architecture, "wrong descriptor");
  axo_mlx_string_free(description);
  auto request = input().dump();
  char* response = axo_mlx_predict(model, request.c_str(), &error);
  diagnostic = error ? error : "";
  axo_mlx_string_free(error);
  check(response != nullptr, diagnostic.c_str());
  auto result = Json::parse(response);
  axo_mlx_string_free(response);
  // Q/K are zero, so attention is the causal mean of RMS-normalized V.
  // The last hidden state has positive coordinates (a/2, 1+a/2).
  // Head row 2 wins, unless row 0's coefficient is changed to 100.
  check(result["next_token"]["value"] == (changed_head ? 0 : 2), "HF weight-driven next token mismatch");
  for (auto bad : {Json{{"input_ids", {{"type", "tensor"}, {"dtype", "float32"}, {"shape", {2}}, {"data", {0, 1}}}}},
                  Json{{"input_ids", {{"type", "tensor"}, {"dtype", "int32"}, {"shape", {1, 4097}}, {"data", {0, 1}}}}},
                  Json{{"input_ids", {{"type", "tensor"}, {"dtype", "int32"}, {"shape", {2}}, {"data", {0, 3}}}}},
                  Json{{"input_ids", {{"type", "tensor"}, {"dtype", "int32"}, {"shape", {2}}, {"data", {0, -1}}}}}}) {
    auto bytes = bad.dump();
    response = axo_mlx_predict(model, bytes.c_str(), &error);
    check(response == nullptr && error != nullptr, "invalid tensor accepted");
    axo_mlx_string_free(error);
  }
  axo_mlx_free(model);
}
void invalid_models_fail_before_use() {
  for (const auto& change : std::vector<Json>{
      {{"hidden_size", 32.5}},
      {{"architectures", Json::array({"Qwen3ForSequenceClassification"})}},
      {{"quantization", {{"bits", 4.5}, {"group_size", 32}}}},
      {{"quantization", {{"bits", 4}, {"group_size", 32}}}, {"quantization_config", {{"bits", 8}, {"group_size", 32}}}},
      {{"rope_scaling", {{"type", "yarn"}}}}}) {
    TemporaryDirectory directory;
    fixture(directory.path, "qwen3", true, false);
    Json config;
    { std::ifstream input(directory.path / "config.json"); input >> config; }
    config.update(change);
    std::ofstream(directory.path / "config.json") << config.dump();
    char* error = nullptr;
    check(axo_mlx_load(directory.path.c_str(), &error) == nullptr && error != nullptr, "unsupported configuration accepted");
    axo_mlx_string_free(error);
  }
  TemporaryDirectory directory;
  fixture(directory.path, "qwen3", false, false);
  auto weights = mx::load_safetensors((directory.path / "model.safetensors").string()).first;
  weights.emplace("custom_decision_head.weight", mx::zeros({3,32}));
  mx::save_safetensors((directory.path / "extra.safetensors").string(), {{"custom_decision_head.weight", weights.at("custom_decision_head.weight")}});
  char* error = nullptr;
  check(axo_mlx_load(directory.path.c_str(), &error) == nullptr && error != nullptr, "custom head was silently discarded");
  axo_mlx_string_free(error);
}

int main(int argc, char** argv) {
  try {
    const auto* resource = std::getenv("AXO_TEST_MLX_METALLIB");
    check(resource != nullptr, "the test must supply its packaged Metal resource");
    auto path = fs::absolute(resource).string();
    char* initialization_error = nullptr;
    check(axo_mlx_initialize(path.c_str(), &initialization_error) == 1,
          initialization_error ? initialization_error : "native MLX initialization failed");
    axo_mlx_string_free(initialization_error);
    if (argc == 3 && std::string(argv[1]) == "--write-fixture") {
      fs::create_directories(argv[2]);
      fixture(argv[2], "qwen3", true, false);
      return 0;
    }
    check(argc == 1, "unknown native test arguments");
    tensor_calculations();
    for (const auto* architecture : {"qwen2", "qwen3"}) {
      for (bool changed : {false, true}) {
        model_test(architecture, false, changed);
        for (int bits : {2, 4, 8})
          for (int group : {32, 64, 128})
            model_test(architecture, true, changed, bits, group);
      }
    }
    invalid_models_fail_before_use();
    char* error = nullptr;
    check(axo_mlx_predict(nullptr, "{}", &error) == nullptr && error != nullptr, "null model accepted");
    axo_mlx_string_free(error);
    std::cout << "MLX native tensor and HF fixture tests passed\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    return 1;
  }
}
