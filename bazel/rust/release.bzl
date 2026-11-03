"""A Rust binary as it ships: optimized and stripped.

Builds and tests run in Bazel's default `fastbuild` mode, where rules_rust compiles with
`opt-level=0` and keeps every symbol. What the app ships is built again in `opt` mode
(`opt-level=3`; rules_rust strips debug info there) and then has its symbol table stripped, which
is most of its size. Only the shipped copy pays for the optimized build.

Stripped, a panic's backtrace shows addresses only. The unstripped binary is kept in the
`unstripped` output group so they can be read back with `atos`.
"""

def _opt_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

_opt_transition = transition(
    implementation = _opt_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _release_binary_impl(ctx):
    binary = ctx.attr.binary[0][DefaultInfo].files_to_run.executable
    # Bundles copy files by name, so it keeps the binary's: declare it in a package of its own.
    stripped = ctx.actions.declare_file(binary.basename)
    ctx.actions.run_shell(
        command = '/bin/cp "$1" "$2" && /bin/chmod u+w "$2" && /usr/bin/strip "$2"',
        arguments = [binary.path, stripped.path],
        inputs = [binary],
        outputs = [stripped],
        mnemonic = "StripBinary",
        progress_message = "Stripping %{label}",
    )
    return [
        DefaultInfo(files = depset([stripped]), executable = stripped),
        OutputGroupInfo(unstripped = depset([binary])),
    ]

release_binary = rule(
    implementation = _release_binary_impl,
    doc = "`binary` built in `opt` mode with its symbols stripped, under the same file name " +
          "(so it needs a package without another file of that name).",
    attrs = {
        "binary": attr.label(mandatory = True, executable = True, cfg = _opt_transition),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    executable = True,
)
