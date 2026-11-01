"""Shared JavaScript test rule (RFD0021)."""

load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")

def node_test(name, tests, data = [], tsx = False, concurrency = None, tests_in_data = False, **kwargs):
    """Runs `node --test` over `tests` from the package's directory, as `npm test` did.

    Args:
        name: The test target's name.
        tests: Test files, relative to the package.
        data: Everything the tests read or import: sources, fixtures and node_modules.
        tsx: Load tsx first, for tests that import `.js` paths of TypeScript files or TypeScript
            packages, which Node does not strip types from under node_modules.
        concurrency: `--test-concurrency`, for suites whose files share ports or state.
        tests_in_data: The tests come in `data` through a js_library. A tagged test (no-sandbox,
            requires-browser...) needs this: its own copies of the files to the output tree would
            carry its tags and clash with other targets' copies of the same files.
        **kwargs: Passed to js_test (tags, size, env...).
    """

    # js_test runs one entry point; `node --test` runs it and every file after it. A generated,
    # empty entry point keeps the test files themselves out of js_test's own copy actions.
    entry = name + ".entry.mjs"
    write_file(
        name = name + "_entry",
        out = entry,
        content = ["// The entry point `node --test` starts from; the tests follow it."],
        testonly = True,
    )
    node_options = []
    if tsx:
        node_options += ["--import", "tsx"]
    node_options.append("--test")
    if concurrency:
        node_options.append("--test-concurrency=%d" % concurrency)
    js_test(
        name = name,
        entry_point = entry,
        args = tests,
        node_options = node_options,
        data = data if tests_in_data else [test for test in tests if test not in data] + data,
        chdir = native.package_name(),
        **kwargs
    )
