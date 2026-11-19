#!/usr/bin/env python3
"""Check or install a signed full companion graph without resetting existing app identities."""
import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import time
import uuid
from pathlib import Path
from common import Release, approved, private_directory, require, require_published_main, source_sha, version_parts

def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--build-evidence', type=Path)
    parser.add_argument('--source', type=source_sha, required=True)
    parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--mode', choices=['check', 'install'], default='check')
    parser.add_argument('--approval-file', type=Path)
    parser.add_argument('--watch-approval-file', type=Path)
    parser.add_argument('--devices', nargs='+', choices=['iPhone', 'iPad', 'appleWatch'], default=['iPhone', 'iPad'])
    args = parser.parse_args(argv)
    if args.mode == 'install':
        require(args.approval_file is not None, 'Installation requires scoped approval')
        require(args.build_evidence is not None, 'Installation requires source-bound build evidence')
    return args

def main(argv=None):
    args = parse_args(argv)
    os.umask(0o077)
    REPO = args.repository.resolve()
    ROOT = private_directory(args.run_dir)
    COMMIT = args.source

    require_published_main(REPO, COMMIT)
    if args.mode == 'install':
        approved(args.approval_file)
        if 'appleWatch' in args.devices:
            require(args.watch_approval_file is not None, 'Watch updates need a separate scoped Watch approval')
            approved(args.watch_approval_file)
    config = json.loads((REPO / 'config.json').read_text())
    release = Release.read(REPO, COMMIT)
    VERSION = release.version
    BUILD = release.mobile_build
    ipa = args.artifact.resolve()
    require(ipa.is_file(), 'Release invariant failed')
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    if args.mode == 'install':
        evidence = json.loads(args.build_evidence.read_text())
        require(evidence['source'] == COMMIT and evidence['version'] == VERSION
                and evidence['artifacts']['mobile']['sha256'] == digest, 'Artifact differs from source-bound build evidence')
    spec = importlib.util.spec_from_file_location('policy', REPO / 'bazel/apple/distribution_preflight.py')
    policy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(policy)
    inspection = type('Args', (), dict(artifact=ipa, channel='development', existing_installation=False, migration=False, require_apns=True, mobile_transfer=False, mobile_probe_only=False))()
    with (ROOT / 'preflight.log').open('w') as log, contextlib.redirect_stdout(log):
        policy.inspect(inspection, config)
    binding = ROOT / 'staged-artifact.json'
    if binding.exists():
        require(json.loads(binding.read_text()) == {'source': COMMIT, 'sha256': digest}, 'Staged artifact changed; reconcile before installation')
        phone = Path((ROOT / 'staged-app-path.txt').read_text())
    else:
        stage = ROOT / 'staged'
        require(not stage.exists(), 'Unbound staging requires inspection')
        stage.mkdir(mode=0o700)
        phone = policy.unpack_ipa(ipa, stage)
        (ROOT / 'staged-app-path.txt').write_text(str(phone))
        binding.write_text(json.dumps({'source': COMMIT, 'sha256': digest}))
    watch = phone / 'Watch/AxoWatchApp.app'
    widget = watch / 'PlugIns/AxoWatchComplicationExtension.appex'
    for app, bundle in [(phone, 'dev.leostera.axo'), (watch, 'dev.leostera.axo.watch'), (widget, 'dev.leostera.axo.watch.complications')]:
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        require((info['CFBundleIdentifier'], info['CFBundleShortVersionString'], info['CFBundleVersion']) == (bundle, VERSION, str(BUILD)), 'Release invariant failed')
        require(info.get('AXOIdentityMigrationMode') not in ('source', 'destination'), 'Normal companion must not run a probe/import gate')
    require(plistlib.loads((watch / 'Info.plist').read_bytes())['WKCompanionAppBundleIdentifier'] == 'dev.leostera.axo', 'Release invariant failed')
    with (ROOT / 'inventory.log').open('w') as log:
        subprocess.run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', str(ROOT / 'devices.json')], stdout=log, stderr=log, check=True, timeout=25)
    devices = json.loads((ROOT / 'devices.json').read_text())['result']['devices']
    kinds = args.devices

    def exclusive(path, value):
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f)
    outcomes = {}
    for kind in kinds:
        folder = ROOT / kind
        folder.mkdir(mode=0o700, exist_ok=True)

        def status(value, **fields):
            outcomes[kind] = value
            (folder / 'status.json').write_text(json.dumps({'status': value, 'source': COMMIT,
                'targetVersion': VERSION, 'targetBuild': BUILD, **fields}))
        matches = [d for d in devices if d.get('hardwareProperties', {}).get('deviceType') == kind]
        if len(matches) != 1:
            status('unavailable')
            print(kind + ': unavailable; no dispatch', flush=True)
            continue
        device = matches[0]
        bundle = 'dev.leostera.axo.watch' if kind == 'appleWatch' else 'dev.leostera.axo'
        app = watch if kind == 'appleWatch' else phone

        def call(label, arguments, timeout=45, required=True, selected=device):
            result = folder / (label + '.json')
            with (folder / (label + '.log')).open('w') as log:
                try:
                    r = subprocess.run(['xcrun', 'devicectl', *arguments[:3], '--device', selected['identifier'], '--timeout', str(timeout - 5), '--json-output', str(result), *arguments[3:]], stdout=log, stderr=log, timeout=timeout)
                except subprocess.TimeoutExpired:
                    raise RuntimeError(label + ' timed out; inspect receipts, never replay')
            if r.returncode:
                if not required:
                    return None
                raise RuntimeError(label + ' failed; inspect private receipt, no automatic retry')
            return json.loads(result.read_text()).get('result', {})

        def installed(label, selected=device, identifier=bundle):
            apps = call(label, ['device', 'info', 'apps', '--include-all-apps', '--bundle-id', identifier], selected=selected)['apps']
            found = [v for v in apps if v.get('bundleIdentifier') == identifier]
            require(len(found) == 1, 'Existing identity is required; never uninstall/reset')
            return (found[0]['version'], found[0]['bundleVersion'])
        try:
            if args.mode == 'check':
                print(kind + ': ' + str(installed('apps-check')), flush=True)
                outcomes[kind] = 'checked'
                continue
            lock = call('lock-before', ['device', 'info', 'lockState'], timeout=20, required=kind != 'appleWatch')
            if lock is not None and lock.get('passcodeRequired') is not False:
                status('locked')
                print(kind + ': locked; no install/launch dispatched', flush=True)
                continue
            if kind == 'appleWatch':
                peer = next((d for d in devices if d.get('hardwareProperties', {}).get('deviceType') == 'iPhone'))
                if installed('paired-phone-before', selected=peer, identifier='dev.leostera.axo') != (VERSION, str(BUILD)):
                    status('waitingForMatchingPhone')
                    print('Watch: held until the matching iPhone build is verified', flush=True)
                    continue
            previous = installed('apps-before')
            if previous != (VERSION, str(BUILD)):
                require(version_parts(previous[0]) <= version_parts(VERSION) and int(previous[1]) < BUILD, 'Never silently downgrade an installed app')
                require(not (folder / 'attempt.json').exists(), 'Prior installation attempt requires reconciliation')
                profile = policy.read_provisioning_profile(app / 'embedded.mobileprovision')
                normalize = lambda s: s.lower().replace('-', '')
                require(normalize(device['hardwareProperties']['udid']) in {normalize(v) for v in profile['ProvisionedDevices']}, 'Release invariant failed')
                exclusive(folder / 'attempt.json', {'source': COMMIT, 'sha256': digest, 'previous': previous})
                status('dispatched')
                if kind == 'iPhone':
                    exclusive(ROOT / 'phone-family-dispatch.json', {'source': COMMIT, 'watchMayAutoInstall': True})
                call('install', ['device', 'install', 'app', str(app)], timeout=110)
                require(installed('apps-after') == (VERSION, str(BUILD)), 'Release invariant failed')
                status('installed')
            else:
                print(kind + ': matching build already installed; no installation replay', flush=True)
            if (folder / 'launch-attempt.json').exists():
                previous_status = json.loads((folder / 'status.json').read_text()).get('status')
                if previous_status in ('launched', 'connected'):
                    outcomes[kind] = previous_status
                    print(kind + ': prior verified launch retained; no replay', flush=True)
                else:
                    status('needsReconciliation')
                    print(kind + ': prior launch requires receipt review; no replay', flush=True)
                continue
            run = str(uuid.uuid4())
            exclusive(folder / 'launch-attempt.json', {'source': COMMIT, 'runID': run})
            env = {} if kind == 'appleWatch' else {'AXO_PUSH_TEST_RUN_ID': run}
            launched = call('launch', ['device', 'process', 'launch', '--terminate-existing', '--environment-variables', json.dumps(env), bundle])
            pid = launched.get('process', {}).get('processIdentifier')
            require(pid is not None, 'Release invariant failed')
            processes = call('processes-after', ['device', 'info', 'processes'])['runningProcesses']
            require(any((v.get('processIdentifier') == pid for v in processes)), 'Release invariant failed')
            status('launched', pidVerified=True)
            print(kind + ': ' + VERSION + '(' + str(BUILD) + ') installed and fresh-launched in place; process verified', flush=True)
            source = 'Library/Application Support/watch-connection.json' if kind == 'appleWatch' else 'Documents/axo-push-test.json'
            for n in range(25):
                time.sleep(1)
                report = folder / 'health-report.json'
                copied = call('report-' + str(n), ['device', 'copy', 'from', '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', source, '--destination', str(report)], timeout=15, required=False)
                if copied is None or not report.exists():
                    continue
                value = json.loads(report.read_text())
                if kind == 'appleWatch':
                    require(set(value) <= {'build', 'transport', 'state', 'updatedAt', 'lastConnectedAt'}, 'Release invariant failed')
                    if value.get('build') == str(BUILD) and value.get('transport') == 'https' and value.get('lastConnectedAt'):
                        status('connected', transport='https')
                        print('Watch: completed authenticated HTTPS account hello verified', flush=True)
                        break
                else:
                    require({'schema', 'runID', 'status'} <= set(value) <= {'schema', 'runID', 'status', 'presentation'} and value['schema'] == 2, 'Release invariant failed')
                    if value['runID'].lower() == run and value['status'] in {'enrolled', 'permissionDenied', 'registrationUnavailable', 'receivedForeground', 'receivedInNotificationCenter'}:
                        status('launched', pushStatus=value['status'])
                        print(kind + ' push: ' + value['status'], flush=True)
                        break
            else:
                print(kind + ': version/process verified; connectivity or enrollment report not yet confirmed', flush=True)
        except Exception as error:
            status('heldOrFailed', errorCategory=type(error).__name__)
            print(kind + ': ' + str(error) + '; no automatic write retry', flush=True)
    complete = ('checked',) if args.mode == 'check' else ('launched', 'connected')
    return 0 if all(outcomes.get(kind) in complete for kind in kinds) else 1


if __name__ == '__main__':
    raise SystemExit(main())
