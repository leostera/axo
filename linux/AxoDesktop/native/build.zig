const std = @import("std");
const Config = @import("src/build/Config.zig");
const SharedDeps = @import("src/build/SharedDeps.zig");
const Resources = @import("src/build/GhosttyResources.zig");

pub fn build(b: *std.Build) !void {
    const config = try Config.init(b, @import("build.zig.zon").version, "0.1.0-dev");
    if (config.target.result.os.tag != .linux or config.app_runtime != .gtk)
        return error.LinuxGtkRuntimeRequired;
    const deps = try SharedDeps.init(b, &config);
    const library = b.addLibrary(.{
        .name = "axo-ghostty-gtk",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/axo_gtk_bridge.zig"),
            .target = config.target,
            .optimize = config.optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    _ = try deps.add(library);
    b.installArtifact(library);
    const resources = try Resources.init(b, &config, &deps);
    resources.install();
}
