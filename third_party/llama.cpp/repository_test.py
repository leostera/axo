"""Test the Python-compatible accelerator configuration without building llama.cpp.

Bazel itself exercises the Starlark evaluator in the real CPU/Metal/CUDA builds.
"""
import pathlib
import types
import unittest


def fail(message):
    raise ValueError(message)


scope = {
    "fail": fail,
    "repository_rule": lambda **kwargs: None,
    "attr": types.SimpleNamespace(string=lambda **kwargs: None),
}
source = pathlib.Path(__file__).with_name("repository.bzl")
exec(compile(source.read_text(), str(source), "exec"), scope)


def configuration(host="linux", **env):
    ctx = types.SimpleNamespace(
        os=types.SimpleNamespace(name=host),
        getenv=lambda name, default=None: env.get(name, default),
    )
    return scope["_accelerator_config"](ctx)


class AcceleratorTests(unittest.TestCase):
    def test_linux_defaults_to_cpu_without_a_toolkit(self):
        backend, options = configuration()
        self.assertEqual(backend, "cpu")
        self.assertIn("-DGGML_METAL=OFF", options)
        self.assertIn("-DGGML_CUDA=OFF", options)
        self.assertFalse(any("CUDA_COMPILER" in option for option in options))

    def test_macos_preserves_embedded_metal(self):
        backend, options = configuration("mac os x")
        self.assertEqual(backend, "metal")
        self.assertIn("-DGGML_METAL=ON", options)
        self.assertIn("-DGGML_METAL_EMBED_LIBRARY=ON", options)
        self.assertIn("-DGGML_CUDA=OFF", options)

    def test_explicit_cpu_disables_both_accelerators(self):
        for host in ("linux", "mac os x"):
            with self.subTest(host=host):
                backend, options = configuration(host, AXO_LLAMA_BACKEND="cpu")
                self.assertEqual(backend, "cpu")
                self.assertIn("-DGGML_METAL=OFF", options)
                self.assertIn("-DGGML_CUDA=OFF", options)

    def test_cuda_has_explicit_architectures_and_no_toolkit_runpath(self):
        backend, options = configuration(
            AXO_LLAMA_BACKEND="cuda",
            AXO_CUDA_ARCHITECTURES="75;120a;120f",
            CUDA_PATH="/opt/cuda",
        )
        self.assertEqual(backend, "cuda")
        for option in (
            "-DGGML_CUDA=ON", "-DGGML_METAL=OFF", "-DGGML_STATIC=ON",
            "-DCMAKE_SKIP_RPATH=ON", "-DCMAKE_CUDA_ARCHITECTURES=75;120a;120f",
            "-DCUDAToolkit_ROOT=/opt/cuda", "-DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc",
        ):
            self.assertIn(option, options)

    def test_unknown_backends_and_wrong_platforms_fail(self):
        for host, backend in (("linux", "vulkan"), ("linux", ""),
                              ("linux", "metal"), ("mac os x", "cuda")):
            with self.subTest(host=host, backend=backend), self.assertRaises(ValueError):
                configuration(host, AXO_LLAMA_BACKEND=backend)

    def test_cuda_requires_explicit_stable_architectures(self):
        for arch in ("", "native", "all", "75;", ";75", "75 80", "75;-O3", "7a5", "${ARCH}"):
            with self.subTest(arch=arch), self.assertRaises(ValueError):
                configuration(AXO_LLAMA_BACKEND="cuda", AXO_CUDA_ARCHITECTURES=arch, CUDA_PATH="/opt/cuda")

    def test_cuda_requires_an_absolute_toolkit_path(self):
        for toolkit in ("", "relative/cuda"):
            with self.subTest(toolkit=toolkit), self.assertRaises(ValueError):
                configuration(AXO_LLAMA_BACKEND="cuda", AXO_CUDA_ARCHITECTURES="75", CUDA_PATH=toolkit)


if __name__ == "__main__":
    unittest.main()
