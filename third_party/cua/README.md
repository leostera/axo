# Embedded native computer runtime

Axo embeds Cua Driver's MIT-licensed `platform-macos` / `platform-windows` runtime
and core at the revision in `MODULE.bazel`. It does not run Cua's daemon or MCP
server. Axod owns the allowlist, permissions and approval gate. Windows omits
composite scripts and secret input forms until those paths can be gated end to end.

`cua-driver-core-skills.patch` carries the pinned runtime's out-of-crate guides
into Bazel's fetched crate. `msvc-spectre-path.patch` lets the Rust Spectre-library
locator use Bazel's explicit Microsoft runtime input. The default locator remains
unchanged when no explicit input is supplied; missing libraries still fail the
build. No mitigation is disabled.

`windows-import-libraries.patch` copies the Windows bindings' import libraries
into the build script's declared output tree. Bazel retires the temporary Cargo
runfiles after the script, so linking against that temporary path fails on Windows.

The x64 package URL and SHA-256 come from Microsoft's Visual Studio 2022 17.14
package catalog (`Microsoft.VC.14.44.17.14.CRT.x64.Desktop.spectre.base`, version
14.44.35226, MSVC directory 14.44.35207). Bazel fetches it only for the Windows
x64 build. These are compiler link inputs, not files copied into the application.
See Microsoft's [Spectre library documentation](https://learn.microsoft.com/en-us/cpp/build/reference/qspectre).
