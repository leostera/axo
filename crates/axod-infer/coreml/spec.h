#pragma once
// Bounded data-only validation before handing a source graph to Apple's compiler.
// Schema reference: coremltools a207b1a3452eafe02f2d870f486287834af2c82d,
// mlmodel/format/{Model,MIL,NeuralNetwork}.proto. No generated/runtime Python code.
#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>

namespace axo::coreml {
inline void check(bool condition, const std::string& reason) {
  if (!condition) throw std::runtime_error(reason);
}
struct Field { uint64_t number; uint64_t wire; std::string_view bytes; uint64_t scalar = 0; };
inline uint64_t varint(std::string_view& data) {
  uint64_t value = 0;
  for (unsigned shift = 0; shift < 70; shift += 7) {
    check(!data.empty(), "truncated Core ML protobuf");
    auto byte = static_cast<unsigned char>(data.front()); data.remove_prefix(1);
    check(shift != 63 || byte <= 1, "Core ML protobuf integer overflow");
    value |= uint64_t(byte & 127) << shift;
    if (!(byte & 128)) return value;
  }
  throw std::runtime_error("invalid Core ML protobuf varint");
}

class Verifier {
  std::function<void(std::string_view)> blob_;
  size_t fields_ = 0;
  size_t operations_ = 0;

  Field next(std::string_view& data) {
    check(++fields_ <= 500000, "Core ML specification exceeds the field budget");
    const auto tag = varint(data);
    Field field{tag >> 3, tag & 7, {}};
    check(field.number > 0 && field.number < (1ull << 29), "invalid Core ML protobuf tag");
    uint64_t length;
    switch (field.wire) {
      case 0: field.scalar = varint(data); return field;
      case 1: length = 8; break;
      case 2: length = varint(data); break;
      case 5: length = 4; break;
      default: throw std::runtime_error("unsupported Core ML protobuf wire type");
    }
    check(length <= data.size(), "truncated Core ML protobuf field");
    field.bytes = data.substr(0, length); data.remove_prefix(length);
    return field;
  }
  void message(const Field& field) { check(field.wire == 2, "expected a Core ML protobuf message"); }
  void depth(unsigned d) { check(d < 32, "Core ML graph nesting exceeds 32"); }

  // A protobuf map entry always has its value at field 2. Validate every occurrence,
  // not just the last: duplicate fields must never hide an unsafe earlier reference.
  template<class F> void map_value(std::string_view data, F visit) {
    unsigned values = 0;
    while (!data.empty()) {
      const auto f = next(data);
      if (f.number == 2) { message(f); visit(f.bytes); ++values; }
    }
    check(values == 1, "ambiguous Core ML map entry");
  }
  void attributes(std::string_view entry, unsigned d) {
    map_value(entry, [&](auto data) { value(data, d + 1); });
  }
  void value_type(std::string_view data, unsigned d) {
    depth(d);
    while (!data.empty()) {
      const auto f = next(data); message(f);
      if (f.number == 1) {
        auto tensor = f.bytes;
        uint64_t rank = 0, dimensions = 0, elements = 1, bytes_per_element = 4;
        while (!tensor.empty()) {
          const auto part = next(tensor);
          if (part.number == 1) {
            check(part.wire == 0 && part.scalar > 0, "invalid ML Program tensor dtype");
            if (part.scalar == 12 || part.scalar == 24 || part.scalar == 34) bytes_per_element = 8;
          }
          if (part.number == 2) { check(part.wire == 0 && part.scalar <= 16, "ML Program tensor rank exceeds 16"); rank = part.scalar; }
          if (part.number == 3) {
            message(part); auto dimension = part.bytes;
            const auto constant = next(dimension);
            check(constant.number == 1 && constant.wire == 2 && dimension.empty(), "dynamic ML Program tensor dimensions need another adapter");
            auto body = constant.bytes;
            const auto size = next(body);
            check(size.number == 1 && size.wire == 0 && size.scalar > 0 && body.empty(), "invalid ML Program dimension");
            check(size.scalar <= 64 * 1024 * 1024 && elements <= (64 * 1024 * 1024) / size.scalar, "ML Program tensor exceeds 64 million elements");
            elements *= size.scalar; ++dimensions;
          }
          if (part.number == 4) { message(part); attributes(part.bytes, d + 1); }
        }
        check(rank == dimensions && elements <= (256 * 1024 * 1024) / bytes_per_element, "ML Program tensor shape or 256 MiB allocation bound exceeded");
      } else if (f.number == 2 || f.number == 3 || f.number == 4) {
        auto nested = f.bytes;
        while (!nested.empty()) {
          const auto part = next(nested);
          if (part.number == 1 || (f.number == 4 && part.number == 2)) { message(part); value_type(part.bytes, d + 1); }
        }
      } else {
        throw std::runtime_error("stateful or unknown Core ML value types need another adapter");
      }
    }
  }
  void named_type(std::string_view data, unsigned d) {
    while (!data.empty()) { const auto f = next(data); if (f.number == 2) { message(f); value_type(f.bytes, d + 1); } }
  }
  void value(std::string_view data, unsigned d) {
    depth(d);
    while (!data.empty()) {
      const auto f = next(data);
      if (f.number == 2) { message(f); value_type(f.bytes, d + 1); }
      if (f.number == 5) {
        message(f); auto blob = f.bytes; unsigned names = 0;
        while (!blob.empty()) {
          const auto part = next(blob);
          if (part.number == 1) { message(part); blob_(part.bytes); ++names; }
        }
        check(names == 1, "ambiguous ML Program blob reference");
      }
      if (f.number == 3) {
        message(f); auto immediate = f.bytes;
        while (!immediate.empty()) {
          const auto part = next(immediate); message(part);
          if (part.number == 1) continue; // Inline tensor values contain data, not references.
          check(part.number >= 2 && part.number <= 4, "unknown ML Program immediate value");
          auto items = part.bytes;
          while (!items.empty()) {
            const auto item = next(items);
            if (item.number != 1) continue;
            message(item);
            if (part.number == 4) {
              auto pair = item.bytes;
              while (!pair.empty()) { const auto entry = next(pair); if (entry.number == 1 || entry.number == 2) { message(entry); value(entry.bytes, d + 1); } }
            } else { value(item.bytes, d + 1); }
          }
        }
      }
    }
  }
  void operation(std::string_view data, unsigned d) {
    check(++operations_ <= 20000, "Core ML graph exceeds 20000 operations");
    static const std::unordered_set<std::string_view> builtins = {
      "const", "identity", "cast", "add", "sub", "mul", "real_div", "floor_div", "mod", "pow",
      "abs", "ceil", "floor", "round", "sign", "clip", "exp", "log", "sqrt", "rsqrt", "inverse",
      "relu", "relu6", "leaky_relu", "prelu", "elu", "gelu", "sigmoid", "sigmoid_hard", "silu", "softmax", "softplus", "tanh",
      "conv", "conv_transpose", "linear", "matmul", "batch_norm", "instance_norm", "layer_norm", "l2_norm",
      "avg_pool", "max_pool", "reduce_mean", "reduce_sum", "reduce_max", "reduce_min", "reduce_prod",
      "reshape", "transpose", "squeeze", "expand_dims", "shape", "concat", "split", "stack", "tile", "pad",
      "slice_by_index", "slice_by_size", "gather", "gather_along_axis", "gather_nd", "scatter", "scatter_along_axis",
      "range_1d", "fill", "one_hot", "select", "equal", "not_equal", "less", "less_equal", "greater", "greater_equal",
      "logical_and", "logical_or", "logical_not", "argmax", "argmin", "topk", "classify",
      "resize_bilinear", "upsample_bilinear", "upsample_nearest_neighbor", "pixel_shuffle", "depth_to_space", "space_to_depth",
      "constexpr_affine_dequantize", "constexpr_lut_to_dense", "constexpr_sparse_to_dense", "constexpr_cast",
      "constexpr_blockwise_shift_scale", "constexpr_lut_to_sparse", "constexpr_sparse_blockwise_shift_scale"
    };
    unsigned types = 0;
    while (!data.empty()) {
      const auto f = next(data);
      if (f.number == 1) { message(f); ++types; check(builtins.count(f.bytes) != 0, "unsupported ML Program operation: " + std::string(f.bytes.substr(0, 128))); }
      else if (f.number == 2) {
        message(f);
        map_value(f.bytes, [&](auto args) {
          while (!args.empty()) {
            const auto binding = next(args); if (binding.number != 1) continue; message(binding);
            auto payload = binding.bytes;
            while (!payload.empty()) { const auto part = next(payload); if (part.number == 2) { message(part); value(part.bytes, d + 1); } }
          }
        });
      } else if (f.number == 3) { message(f); named_type(f.bytes, d + 1); }
      else if (f.number == 4) { throw std::runtime_error("nested/control-flow ML Program blocks are not implemented"); }
      else if (f.number == 5) { message(f); attributes(f.bytes, d + 1); }
    }
    check(types == 1, "ambiguous ML Program operation type");
  }
  void block(std::string_view data, unsigned d) {
    depth(d);
    while (!data.empty()) {
      const auto f = next(data);
      if (f.number == 1) { message(f); named_type(f.bytes, d + 1); }
      if (f.number == 3) { message(f); operation(f.bytes, d + 1); }
      if (f.number == 4) { message(f); attributes(f.bytes, d + 1); }
    }
  }
  void function(std::string_view data, unsigned d) {
    depth(d); unsigned blocks = 0;
    while (!data.empty()) {
      const auto f = next(data);
      if (f.number == 1) { message(f); named_type(f.bytes, d + 1); }
      if (f.number == 3) { message(f); map_value(f.bytes, [&](auto b) { block(b, d + 1); }); ++blocks; }
      if (f.number == 4) { message(f); attributes(f.bytes, d + 1); }
    }
    check(blocks > 0, "ML Program function has no block");
  }
  void program(std::string_view data, unsigned d) {
    unsigned functions = 0;
    while (!data.empty()) {
      const auto f = next(data);
      if (f.number == 2) { message(f); map_value(f.bytes, [&](auto fn) { function(fn, d + 1); }); ++functions; }
      if (f.number == 4) { message(f); attributes(f.bytes, d + 1); }
    }
    check(functions > 0, "ML Program has no function");
  }
  void network(std::string_view data) {
    while (!data.empty()) {
      const auto f = next(data); if (f.number != 1) continue; message(f);
      auto layer = f.bytes;
      while (!layer.empty()) { const auto part = next(layer); check(part.number != 500 && part.number != 605 && part.number != 615, "custom or control-flow neural layers are unsupported"); }
    }
  }
 public:
  explicit Verifier(std::function<void(std::string_view)> blob) : blob_(std::move(blob)) {}
  void model(std::string_view data, unsigned d = 0) {
    depth(d); unsigned types = 0;
    while (!data.empty()) {
      const auto f = next(data); if (f.number < 200) continue; message(f);
      check(++types == 1, "ambiguous Core ML model type");
      switch (f.number) {
        case 200: case 201: case 202: {
          auto pipeline = f.bytes;
          if (f.number != 202) { const auto wrapper = next(pipeline); check(wrapper.number == 1 && wrapper.wire == 2 && pipeline.empty(), "invalid pipeline wrapper"); pipeline = wrapper.bytes; }
          while (!pipeline.empty()) { const auto child = next(pipeline); if (child.number == 1) { message(child); model(child.bytes, d + 1); } }
          break;
        }
        case 303: case 403: case 500: network(f.bytes); break;
        case 502: program(f.bytes, d + 1); break;
        case 300: case 301: case 302: case 304: case 400: case 401: case 402: case 404:
        case 600: case 601: case 602: case 603: case 604: case 606: case 607: case 609: case 610: case 900: break;
        default: throw std::runtime_error("custom, linked, or unknown Core ML model type is unsupported");
      }
    }
    check(types == 1, "missing Core ML model type");
  }
};
} // namespace axo::coreml
