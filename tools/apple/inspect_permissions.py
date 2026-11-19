#!/usr/bin/env python3
"""Read the actual daemon's permission owner without granting, resetting or reading TCC databases."""
import ctypes
import json
import os
from pathlib import Path
import sys

from install_mac import rpc


def process_path(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    function = library.proc_pidpath
    function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    function.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    return os.fsdecode(buffer.value) if function(pid, buffer, len(buffer)) > 0 else None


def responsible_pid(pid):
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    try:
        function = library.responsibility_get_pid_responsible_for_pid
    except AttributeError:
        return None
    function.argtypes = [ctypes.c_int]
    function.restype = ctypes.c_int
    value = function(pid)
    return value if value > 0 else None


def summarize(report, executable, responsible, expected):
    pid = report.get("processId")
    if type(pid) is not int or pid <= 0:
        raise RuntimeError("Daemon did not report a valid process identity")
    states = {"granted", "notGranted", "notAsked", "notRunning", "unknown", "unsupported"}
    return {
        "processId": pid,
        "installedHelperMatchesRunningPath": None if executable is None else executable == str(expected),
        "daemonIsResponsibleProcess": None if responsible is None else responsible == pid,
        "permissions": {key: value if isinstance(value, str) and value in states else "unknown" for key, value in report.items()
                        if key in ("developerTools", "accessibility", "inputControl", "screenRecording", "fullDiskAccess",
                                   "automationFinder", "automationSystemEvents")},
    }


def main():
    if sys.platform != "darwin":
        raise RuntimeError("This read-only inspection requires macOS")
    report = rpc("axo.daemon.permissions")
    pid = report.get("processId")
    if type(pid) is not int or pid <= 0:
        raise RuntimeError("Daemon did not report a valid process identity")
    expected = Path("/Applications/Axo.app/Contents/Helpers/axod")
    print(json.dumps(summarize(report, process_path(pid), responsible_pid(pid), expected), indent=2))


if __name__ == "__main__":
    main()
