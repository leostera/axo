#!/usr/bin/python3
"""Explicit GTK creation against one owned axod; no production HOME/sockets."""
import json
import os
import pathlib
import runpy
import shlex
import signal
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib
from reconnect_proxy import OwnedProxy

if os.environ.get('AXO_DESKTOP_ISOLATED') != '1':
    raise SystemExit('use the isolated desktop launcher')
binary, run = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2])
here = pathlib.Path(__file__).resolve().parent
repository = here.parents[2]
rpc = runpy.run_path(str(repository/'linux/smoke.py'))['rpc']
ipc = run/'server/axod.sock'
processes, logs = [], []
proxy = None


def start(command, name, **options):
    log = (run/f'{name}.log').open('w')
    logs.append(log)
    process = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True, **options)
    processes.append(process)
    return process


def wait(description, check, process, timeout=25):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if process.poll() is not None:
            raise RuntimeError(f'{description}: process exited {process.returncode}; {run}')
        try:
            value = check()
            if value:
                return value
        except (OSError, ValueError, KeyError, IndexError, GLib.Error, subprocess.CalledProcessError):
            pass
        time.sleep(.05)
    dump_accessibility()
    raise RuntimeError(f'timed out: {description}; {run}')


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str, args)], text=True, stderr=subprocess.PIPE).strip()


def accessible(app, text, prefix=False):
    desktop = Atspi.get_desktop(0)
    pending = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    pending = [node for node in pending if node is not None and node.get_process_id() == app.pid]
    while pending:
        node = pending.pop()
        if node is None:
            continue
        try:
            name = node.get_name() or ''
            if node.get_state_set().contains(Atspi.StateType.SHOWING) and (
                    name.startswith(text) if prefix else name == text or node.get_description() == text):
                return node
            pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))
        except GLib.Error:
            pass


def dump_accessibility():
    desktop = Atspi.get_desktop(0)
    pending = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    rows = []
    while pending:
        node = pending.pop()
        if node is None:
            continue
        try:
            rows.append({'name':node.get_name(), 'role':node.get_role_name(), 'showing':node.get_state_set().contains(Atspi.StateType.SHOWING)})
            pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))
        except GLib.Error:
            pass
    (run/'creation-accessibility.json').write_text(json.dumps(rows))
    try:
        windows = xdo('search', '--name', '.').splitlines()
        (run/'creation-windows.json').write_text(json.dumps({window:xdo('getwindowname', window) for window in windows}))
    except subprocess.CalledProcessError:
        pass


def click(app, text):
    node = wait(f'accessible {text}', lambda: accessible(app, text), app)
    if node.get_role() in [Atspi.Role.PUSH_BUTTON, Atspi.Role.TOGGLE_BUTTON]:
        action = node.get_action_iface()
        if action is not None and action.get_n_actions() > 0:
            assert action.do_action(0), f'accessible activation refused: {text}'
            return
    rect = node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    assert rect.width > 0 and rect.height > 0
    with (run/'creation-clicks.jsonl').open('a') as trace:
        trace.write(json.dumps({'text':text, 'name':node.get_name(), 'role':node.get_role_name(), 'rect':[rect.x,rect.y,rect.width,rect.height], 'active':xdo('getactivewindow')})+'\n')
    xdo('mousemove', '--window', xdo('getactivewindow'), rect.x + rect.width//2, rect.y + rect.height//2)
    xdo('click', '1')


def catalog():
    return rpc(ipc, 'axo.session.catalog', {})['sessions']


def new_record(before):
    return next((record for record in catalog() if record['id'] not in before), None)


start(['openbox'], 'openbox')
time.sleep(.2)
pi = run/'owned-pi.sh'
pi.write_text('#!/bin/sh\nprintf "PI_WORKBENCH_READY\\n"\nexec /bin/sleep 300\n')
pi.chmod(0o700)
env = dict(os.environ, AXO_PI_EXECUTABLE=str(pi), AXO_PI_EXTENSION_PATH=str(repository/'crates/axo-server/testdata/pi-extension.js'))
daemon = start([os.environ['AXOD_BINARY'], '--server-dir', str(run/'server'), '--socket', str(ipc),
                '--host-credentials', 'files', '--relay-url', 'http://127.0.0.1:9'], 'daemon', env=env)
try:
    wait('owned daemon ready', lambda: ipc.exists() and rpc(ipc, 'axo.daemon.health', {})['ready'], daemon)
    terminal = run/'owned-terminal.sh'
    terminal.write_text('#!/bin/sh\nexec '+shlex.join(['/usr/bin/python3', '-u', str(here/'terminal_fixture.py')])+' "$HOME/creation-$$.json"\n')
    terminal.chmod(0o700)
    rpc(ipc, 'axo.config.set', {'key':'shell.command', 'value':str(terminal)})
    original_folder = run/'home'/'original-context'
    chosen_folder = run/'home'/'chosen-directory'
    original_folder.mkdir()
    chosen_folder.mkdir()
    original = rpc(ipc, 'axo.session.create', {'folder':str(original_folder)})
    rpc(ipc, 'axo.session.rename', {'sessionId':original['id'], 'name':'creation-original'})
    original_pids = {pane['id']:pane['processId'] for pane in original['shells']}
    proxy = OwnedProxy(run, ipc, allow_actions={'axo.session.create'})
    diagnostics = run/'creation.json'
    app = start([str(binary), '--socket', str(proxy.rpc_path), '--diagnostics', str(diagnostics)], 'creation', cwd=run/'home')
    window = wait('GTK workbench', lambda: xdo('search', '--onlyvisible', '--pid', app.pid, '--name', '^Axo').splitlines()[0], app)
    xdo('windowactivate', '--sync', window)

    def selected(record):
        data = json.loads(diagnostics.read_text())
        return data if data['sessionId'] == record['id'] and {p['shellId'] for p in data['panes'] if p['ready']} == {p['id'] for p in record['shells']} else None

    def count():
        with proxy.lock:
            return proxy.methods.count('axo.session.create')

    wait('original panes', lambda: selected(original), app)
    before = {record['id'] for record in catalog()}
    xdo('key', '--clearmodifiers', 'ctrl+n')
    beside = wait('new Session in current context', lambda: new_record(before), app)
    assert beside['folder'] == str(original_folder)
    wait('new current-context Session selected', lambda: selected(beside), app)
    assert count() == 1

    before = {record['id'] for record in catalog()}
    click(app, 'New Session')
    click(app, 'New Session at Home')
    home = wait('new Session at owned HOME', lambda: new_record(before), app)
    assert home['folder'] == str(run/'home')
    wait('home Session selected', lambda: selected(home), app)
    assert count() == 2

    # Cancelling the native folder chooser is not creation intent.
    xdo('key', '--clearmodifiers', 'ctrl+shift+n')
    chooser = wait('native folder chooser', lambda: xdo('search', '--onlyvisible', '--name', '^New Session in Folder$').splitlines()[0], app)
    xdo('windowactivate', '--sync', chooser)
    xdo('key', '--clearmodifiers', 'Escape')
    time.sleep(.2)
    assert count() == 2
    xdo('key', '--clearmodifiers', 'ctrl+shift+n')
    chooser = wait('native folder chooser again', lambda: xdo('search', '--onlyvisible', '--name', '^New Session in Folder$').splitlines()[0], app)
    xdo('windowactivate', '--sync', chooser)
    before = {record['id'] for record in catalog()}
    xdo('key', '--clearmodifiers', 'ctrl+l')
    xdo('type', '--clearmodifiers', str(chosen_folder))
    xdo('key', '--clearmodifiers', 'Return')
    time.sleep(.2)
    # Gtk's portal chooser can keep the directory open on the first Enter.
    if xdo('getactivewindow') == chooser:
        xdo('key', '--clearmodifiers', 'Return')
    chosen = wait('new Session in chosen folder', lambda: new_record(before), app)
    assert chosen['folder'] == str(chosen_folder)
    wait('folder Session selected', lambda: selected(chosen), app)
    assert count() == 3

    # Hold an admitted reply. Duplicate accelerators must not create, and a later
    # explicit selection must win over completion of the original creation intent.
    proxy.create_gate.clear()
    before = {record['id'] for record in catalog()}
    xdo('key', '--clearmodifiers', 'ctrl+n')
    late = wait('admitted held creation', lambda: new_record(before), app)
    xdo('key', '--clearmodifiers', 'ctrl+n', 'ctrl+n')
    click(app, 'creation-original')
    wait('person changed selection while pending', lambda: selected(original), app)
    assert count() == 4
    proxy.create_gate.set()
    wait('pending creation completed', lambda: accessible(app, 'Creating Session…') is None, app)
    time.sleep(.3)
    assert selected(original), 'late reply stole a newer explicit selection'
    assert count() == 4

    # Lose the admitted reply: read refresh/reconnect/resize cannot replay creation
    # or silently enable another non-idempotent intent.
    proxy.lose_create_ack = True
    before = {record['id'] for record in catalog()}
    xdo('key', '--clearmodifiers', 'ctrl+n')
    uncertain = wait('creation really admitted before acknowledgement loss', lambda: new_record(before), app)
    wait('explicit unconfirmed-creation notice', lambda: accessible(app, 'Creation was not confirmed:', prefix=True), app)
    assert count() == 5
    xdo('key', '--clearmodifiers', 'ctrl+n')
    xdo('windowsize', window, 1300, 820)
    click(app, 'Refresh Sessions')
    epoch = json.loads(diagnostics.read_text())['catalogEpoch']
    proxy.cut('rpc')
    wait('read-only epoch recovery', lambda: json.loads(diagnostics.read_text())['catalogEpoch'] > epoch, app)
    xdo('key', '--clearmodifiers', 'ctrl+n')
    time.sleep(.3)
    assert count() == 5, 'uncertain creation was repeated by refresh/reconnect/geometry'
    assert len(catalog()) == len(before) + 1
    click(app, "I've reviewed Sessions")
    wait('explicit review acknowledged without replay', lambda: accessible(app, "I've reviewed Sessions") is None, app)
    assert count() == 5, 'acknowledgement itself retried creation'
    proxy.lose_create_ack = False
    before = {record['id'] for record in catalog()}
    xdo('key', '--clearmodifiers', 'ctrl+n')
    final = wait('new distinct explicit intent after review', lambda: new_record(before), app)
    wait('new intent selected', lambda: selected(final), app)
    assert count() == 6
    current_original = next(record for record in catalog() if record['id'] == original['id'])
    assert {pane['id']:pane['processId'] for pane in current_original['shells']} == original_pids
    assert not proxy.errors, proxy.errors
    proxy.create_gate.clear()
    before = {record['id'] for record in catalog()}
    xdo('key', '--clearmodifiers', 'ctrl+n')
    pending_exit = wait('creation admitted before window close', lambda: new_record(before), app)
    assert count() == 7
    xdo('windowactivate', '--sync', window)
    xdo('key', '--clearmodifiers', 'alt+F4')
    app.wait(timeout=8)
    assert app.returncode == 0, app.returncode
    frontend_log = (run/'creation.log').read_text()
    assert 'clean shutdown; terminal widgets released' in frontend_log
    assert 'error getting termios mode' not in frontend_log
    assert 'CRITICAL' not in frontend_log
    assert any(record['id'] == pending_exit['id'] for record in catalog())
    assert count() == 7
    assert {pane['id']:pane['processId'] for record in catalog() if record['id'] == original['id'] for pane in record['shells']} == original_pids
    print(json.dumps({'status':'passed', 'checks':['typed create current/home/native folder', 'chooser cancel sends nothing', 'one pending mutation', 'late reply preserves newer selection', 'lost admitted creation acknowledgement fences further intent across refresh/reconnect/resize', 'explicit review does not replay', 'new explicit intent after review', 'original children survive', 'close during admitted creation cancels delivery without replay']}))
finally:
    if proxy is not None:
        proxy.close()
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    for log in logs:
        log.close()
