"""rust-project.json for rust-analyzer, written by a build action (RFD0021)."""

load("//bazel/apple:defs.bzl", "StatusInfo")

def _rust_project_install_impl(ctx):
    status = ctx.actions.declare_file(ctx.attr.name + ".status")
    log = ctx.actions.declare_file(ctx.attr.name + ".log")
    gen = ctx.attr._gen[DefaultInfo].files_to_run
    ctx.actions.run(
        executable = ctx.executable._install,
        arguments = [
            gen.executable.path,
            ctx.attr.workspace,
            ctx.attr.bazel,
            ctx.attr.home,
            ctx.attr.output_base,
            status.path,
            log.path,
        ],
        # The project changes with the files under crates/ and the crates MODULE.bazel declares;
        # `state` brings it back when it is deleted.
        inputs = [ctx.file.files, ctx.file.state] + ctx.files.module,
        tools = [gen],
        outputs = [status, log],
        # It writes into the workspace and runs a Bazel of its own: never sandboxed, remote or cached.
        execution_requirements = {"local": "1", "no-cache": "1", "no-remote": "1", "no-sandbox": "1"},
        mnemonic = "RustProject",
        progress_message = "Generating rust-project.json",
    )
    return [
        DefaultInfo(files = depset([status, log])),
        StatusInfo(files = depset([status])),
    ]

rust_project_install = rule(
    implementation = _rust_project_install_impl,
    doc = "Writes rust-project.json into the workspace for the crates under crates/.",
    attrs = {
        "bazel": attr.string(doc = "The bazel gen_rust_project runs, as found on PATH."),
        "files": attr.label(allow_single_file = True, default = "@axo_files//:crates_files.txt"),
        "home": attr.string(),
        "module": attr.label_list(allow_files = True, default = ["//:MODULE.bazel", "//:MODULE.bazel.lock"]),
        "output_base": attr.string(mandatory = True, doc = "gen_rust_project's own output base."),
        "state": attr.label(allow_single_file = True, default = "@axo_config//:install_state.txt"),
        "workspace": attr.string(mandatory = True),
        "_gen": attr.label(default = "@rules_rust//tools/rust_analyzer:gen_rust_project", executable = True, cfg = "exec"),
        "_install": attr.label(default = ":install_rust_project.sh", executable = True, cfg = "exec", allow_single_file = True),
    },
)
