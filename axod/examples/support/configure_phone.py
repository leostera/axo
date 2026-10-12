"""Prepare a private xctestrun from Rust's captured Mac observation, never credentials."""
import json
import os
import plistlib
import sys
from pathlib import Path
from uuid import UUID


def configure(source: Path, destination: Path, observation: Path) -> None:
    captured = json.loads(observation.read_bytes())
    runtimes = [str(UUID(value)) for value in captured["runtimeGenerations"]]
    if len(runtimes) != 2 or len(set(runtimes)) != 2:
        raise ValueError("Two distinct captured runtime identities required")
    environment = {
        "AXO_E2E_MACHINE_ID": str(UUID(captured["target"]["machineId"])),
        "AXO_E2E_HOST_GENERATION": str(UUID(captured["target"]["hostGeneration"])),
        "AXO_E2E_SESSION_ID": str(UUID(captured["sessionId"])),
        "AXO_E2E_RUNTIMES": ",".join(runtimes),
    }
    configuration = plistlib.loads(source.read_bytes())
    targets = 0

    def rewrite(value):
        nonlocal targets
        if isinstance(value, dict):
            if value.get("BlueprintName") == "AxoPhoneUITests":
                targets += 1
                value.setdefault("EnvironmentVariables", {}).update(environment)
            return {key: rewrite(item) for key, item in value.items()}
        if isinstance(value, list):
            return [rewrite(item) for item in value]
        if isinstance(value, str):
            # Moving the run file must not change its original product authority.
            return value.replace("__TESTROOT__", str(source.parent))
        return value

    configuration = rewrite(configuration)
    if targets != 1:
        raise ValueError("Exactly one phone UI-test target required")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        plistlib.dump(configuration, output)
        output.flush()
        os.fsync(output.fileno())


if __name__ == "__main__":
    configure(*(Path(argument) for argument in sys.argv[1:]))
