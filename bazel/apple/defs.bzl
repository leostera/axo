"""Signing the Mac app and putting it at dist/Axo.app, as build actions (RFD0021)."""

# Actions that need the keychain, the network (codesign's secure timestamp) or that write into the
# workspace cannot run in the sandbox, remotely or from a cache.
_LOCAL = {
    "local": "1",
    "no-remote": "1",
    "no-sandbox": "1",
}

StatusInfo = provider(
    doc = "One line for the build report: what a piece of the build did, or why it fell back.",
    fields = {"files": "depset of files, each one status line"},
)

def _signed_mac_app_impl(ctx):
    app = ctx.actions.declare_directory(ctx.attr.name + "/Axo.app")
    status = ctx.actions.declare_file(ctx.attr.name + ".status")
    ctx.actions.run(
        executable = ctx.executable._sign,
        arguments = [ctx.file.app.path, app.path, status.path, ctx.attr.identity],
        inputs = [ctx.file.app],
        outputs = [app, status],
        execution_requirements = _LOCAL | {"requires-network": "1"},
        mnemonic = "SignMacApp",
        progress_message = "Signing %{label}",
    )
    return [
        DefaultInfo(files = depset([app]), runfiles = ctx.runfiles([app])),
        StatusInfo(files = depset([status])),
    ]

signed_mac_app = rule(
    implementation = _signed_mac_app_impl,
    doc = "The Mac app unpacked and signed with `identity` (hardened runtime, secure timestamp), or ad hoc when it is empty or unusable.",
    attrs = {
        "app": attr.label(allow_single_file = [".zip"], mandatory = True, doc = "The macos_application."),
        "identity": attr.string(doc = "A signing identity's SHA-1, or empty for ad hoc."),
        "_sign": attr.label(default = ":sign_mac_app.sh", executable = True, cfg = "exec", allow_single_file = True),
    },
)

def _mac_app_install_impl(ctx):
    status = ctx.actions.declare_file(ctx.attr.name + ".status")
    app = ctx.files.app[0]
    ctx.actions.run(
        executable = ctx.executable._install,
        arguments = [app.path, ctx.attr.destination, status.path],
        # `state` changes when the installed bundle appears or disappears, so deleting it brings it back.
        inputs = [app, ctx.file.state],
        outputs = [status],
        execution_requirements = _LOCAL | {"no-cache": "1"},
        mnemonic = "InstallMacApp",
        progress_message = "Installing %{label} at " + ctx.attr.destination,
    )
    return [
        DefaultInfo(files = depset([status])),
        StatusInfo(files = depset([status])),
    ]

mac_app_install = rule(
    implementation = _mac_app_install_impl,
    doc = "Swaps the built app in at `destination`, an absolute path in the workspace.",
    attrs = {
        "app": attr.label(mandatory = True, doc = "A signed_mac_app."),
        "destination": attr.string(mandatory = True),
        "state": attr.label(allow_single_file = True, default = "@axo_config//:install_state.txt"),
        "_install": attr.label(default = ":install_app", executable = True, cfg = "exec"),
    },
)

def _build_report_impl(ctx):
    report = ctx.actions.declare_file(ctx.attr.name + ".txt")
    statuses = depset(transitive = [target[StatusInfo].files for target in ctx.attr.pieces])
    inputs = [ctx.file.machine] + statuses.to_list()
    ctx.actions.run_shell(
        # Printed to stderr too, so Bazel shows it whenever it changes.
        command = 'out=$1; shift; { echo "Axo build report"; for f in "$@"; do sed "s/^/  /" "$f"; done; } > "$out"; cat "$out" >&2',
        arguments = [report.path] + [f.path for f in inputs],
        inputs = inputs,
        outputs = [report],
        mnemonic = "AxoBuildReport",
        progress_message = "Writing the build report",
    )
    return [DefaultInfo(files = depset([report]))]

build_report = rule(
    implementation = _build_report_impl,
    doc = "bazel-bin/<name>.txt: what every optional piece of the build did, and this Mac's facts.",
    attrs = {
        "machine": attr.label(allow_single_file = True, default = "@axo_config//:machine.txt"),
        "pieces": attr.label_list(providers = [StatusInfo]),
    },
)

def _ios_device_transition_impl(_settings, _attr):
    return {"//command_line_option:ios_multi_cpus": ["arm64"]}

_ios_device_transition = transition(
    implementation = _ios_device_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:ios_multi_cpus"],
)

def _ios_device_app_impl(ctx):
    status = ctx.actions.declare_file(ctx.attr.name + ".status")
    ctx.actions.write(status, "AxoPhoneDevice: built for a phone\n")
    return [
        DefaultInfo(files = ctx.attr.app[0][DefaultInfo].files),
        StatusInfo(files = depset([status])),
    ]

ios_device_app = rule(
    implementation = _ios_device_app_impl,
    doc = "An ios_application built for a phone (arm64) in the same build as the simulator targets.",
    attrs = {"app": attr.label(mandatory = True, cfg = _ios_device_transition)},
)

def _phone_install_impl(ctx):
    status = ctx.actions.declare_file(ctx.attr.name + ".status")
    inputs = ctx.files.app
    ctx.actions.run(
        executable = ctx.executable._install,
        arguments = [
            inputs[0].path if inputs else "",
            ctx.attr.device,
            ctx.attr.bundle_id,
            status.path,
            ctx.attr.off,
        ],
        inputs = inputs,
        outputs = [status],
        execution_requirements = _LOCAL | {"no-cache": "1"},
        mnemonic = "InstallPhoneApp",
        progress_message = "Installing %{label} on the phone",
    )
    return [
        DefaultInfo(files = depset([status])),
        StatusInfo(files = depset([status])),
    ]

phone_install = rule(
    implementation = _phone_install_impl,
    doc = "Installs the device build on the phone, or reports why it did not (`off`).",
    attrs = {
        "app": attr.label(doc = "An ios_device_app; empty when this Mac cannot build one.", allow_files = True),
        "bundle_id": attr.string(mandatory = True),
        "device": attr.string(),
        "off": attr.string(doc = "Why installing is off; empty to install."),
        "_install": attr.label(default = ":install_phone_app.sh", executable = True, cfg = "exec", allow_single_file = True),
    },
)

def _phone_reinstall_impl(ctx):
    launcher = ctx.actions.declare_file(ctx.attr.name + ".sh")
    app = ctx.files.app
    ctx.actions.write(
        launcher,
        "\n".join([
            "#!/bin/bash",
            "# Installs and opens the last device build on the phone again (`bazel run`).",
            "set -euo pipefail",
            "cd \"${RUNFILES_DIR:-$0.runfiles}/_main\"",
            "exec %s %s %s %s /dev/stdout %s" % (
                ctx.executable._install.short_path,
                repr(app[0].short_path if app else ""),
                repr(ctx.attr.device),
                repr(ctx.attr.bundle_id),
                repr(ctx.attr.off),
            ),
            "",
        ]),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = app + [ctx.executable._install])
    return [DefaultInfo(executable = launcher, runfiles = runfiles)]

phone_reinstall = rule(
    implementation = _phone_reinstall_impl,
    executable = True,
    doc = """Installs and opens the last device build on the phone with `bazel run`, every time.

    `phone_install` runs once per new build: Bazel's action cache skips it while its inputs are
    the same, so after a failed or locked install, this is how to try again.""",
    attrs = {
        "app": attr.label(doc = "An ios_device_app; empty when this Mac cannot build one.", allow_files = True),
        "bundle_id": attr.string(mandatory = True),
        "device": attr.string(),
        "off": attr.string(doc = "Why installing is off; empty to install."),
        "_install": attr.label(default = ":install_phone_app.sh", executable = True, cfg = "target", allow_single_file = True),
    },
)

def _status_line_impl(ctx):
    status = ctx.actions.declare_file(ctx.attr.name + ".status")
    ctx.actions.write(status, ctx.attr.line + "\n")
    return [DefaultInfo(files = depset([status])), StatusInfo(files = depset([status]))]

status_line = rule(
    implementation = _status_line_impl,
    doc = "A fixed line for the build report, for a piece this Mac skips.",
    attrs = {"line": attr.string(mandatory = True)},
)

def _xcodeproj_install_impl(ctx):
    status = ctx.actions.declare_file(ctx.attr.name + ".status")
    log = ctx.actions.declare_file(ctx.attr.name + ".log")
    runner = ctx.attr.runner[DefaultInfo].files_to_run
    ctx.actions.run(
        executable = ctx.executable._install,
        arguments = [
            runner.executable.path,
            ctx.attr.workspace,
            ctx.attr.bazel,
            ctx.attr.home,
            status.path,
            log.path,
            ctx.attr.retry,
        ],
        # The project changes with the files under apple/ and the targets the runner is made for;
        # `state` brings it back when it is deleted.
        inputs = [ctx.file.files, ctx.file.state],
        tools = [runner],
        outputs = [status, log],
        execution_requirements = _LOCAL | {"no-cache": "1"},
        mnemonic = "XcodeProject",
        progress_message = "Generating apple/Axo.xcodeproj",
    )
    return [
        DefaultInfo(files = depset([status, log])),
        StatusInfo(files = depset([status])),
    ]

xcodeproj_install = rule(
    implementation = _xcodeproj_install_impl,
    doc = "Writes the Xcode project of an xcodeproj target into the workspace, as `bazel run` of it does.",
    attrs = {
        "bazel": attr.string(doc = "The bazel the project's own builds run, as found on PATH."),
        "files": attr.label(allow_single_file = True, default = "@axo_files//:apple_files.txt"),
        "home": attr.string(),
        "runner": attr.label(mandatory = True, executable = True, cfg = "target", doc = "An xcodeproj target."),
        "retry": attr.string(mandatory = True, doc = "Where to leave a note when it fails, for @axo_config to retry it."),
        "state": attr.label(allow_single_file = True, default = "@axo_config//:install_state.txt"),
        "workspace": attr.string(mandatory = True),
        "_install": attr.label(default = ":install_xcodeproj.sh", executable = True, cfg = "exec", allow_single_file = True),
    },
)
