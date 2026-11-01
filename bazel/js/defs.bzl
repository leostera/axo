"""Shared JavaScript test rule (RFD0021)."""

load("@aspect_rules_js//js:defs.bzl", "js_test")

def node_test(name, tests, data = [], tsx = False, concurrency = None, **kwargs):
    """Runs `node --test` over `tests` from the package's directory, as `npm test` did.

    Args:
        name: The test target's name.
        tests: Test files, relative to the package.
        data: Everything the tests read or import: sources, fixtures and node_modules.
        tsx: Load tsx first, for tests that import `.js` paths of TypeScript files.
        concurrency: `--test-concurrency`, for suites whose files share ports or state.
        **kwargs: Passed to js_test (tags, size, env...).
    """
    node_options = []
    if tsx:
        node_options += ["--import", "tsx"]
    node_options.append("--test")
    if concurrency:
        node_options.append("--test-concurrency=%d" % concurrency)
    js_test(
        name = name,
        entry_point = tests[0],
        args = tests[1:],
        node_options = node_options,
        data = [test for test in tests if test not in data] + data,
        chdir = native.package_name(),
        **kwargs
    )
