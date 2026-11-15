#!/usr/bin/python3
"""Owned axod/catalog -> two real Ghostty panes; private Xvfb/D-Bus/HOME only."""
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
gi.require_version('GdkPixbuf', '2.0')
from gi.repository import Atspi, GdkPixbuf, GLib

if os.environ.get('AXO_DESKTOP_ISOLATED') != '1':
    raise SystemExit('use the isolated desktop launcher')
binary, run = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2])
here = pathlib.Path(__file__).resolve().parent
repository = here.parents[2]
rpc = runpy.run_path(str(repository / 'linux/smoke.py'))['rpc']
ipc = run / 'server/axod.sock'
processes, logs = [], []


def start(command, name, **options):
    log = (run / f'{name}.log').open('w')
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
        time.sleep(0.05)
    raise RuntimeError(f'timed out: {description}; {run}')


def read(path):
    return json.loads(path.read_text())


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str, args)], text=True, stderr=subprocess.PIPE).strip()


def find_label(app, text):
    desktop = Atspi.get_desktop(0)
    apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    pending = [node for node in apps if node.get_process_id() == app.pid]
    while pending:
        node = pending.pop()
        name = node.get_name()
        if node.get_role_name() in ['label', 'push button'] and (name == text or name.endswith(' ' + text)):
            return node
        pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))


def click_label(app, window, text, below=0):
    node = wait(f'accessible label {text}', lambda: find_label(app, text), app)
    rect = node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('mousemove', '--window', window, rect.x + max(5, rect.width // 2), rect.y + rect.height // 2 + below)
    xdo('click', '1')


def rendered_text(app, window):
    xdo('windowactivate', '--sync', window)
    xdo('key', '--clearmodifiers', 'ctrl+shift+a')
    xdo('key', '--clearmodifiers', 'ctrl+shift+c')
    def copied():
        return json.loads(subprocess.check_output(['/usr/bin/python3', str(here/'clipboard_text.py')], text=True, timeout=5))['text']
    return wait('native terminal clipboard text', copied, app)


def stop(app, window):
    xdo('windowactivate', '--sync', window)
    xdo('key', '--clearmodifiers', 'alt+F4')
    assert app.wait(timeout=5) == 0
    log = (run/'workbench.log').read_text()
    assert 'clean shutdown; terminal widgets released' in log
    assert 'error getting termios mode' not in log, 'termios was queried on the output socket, not the master'


wm = start(['openbox', '--sm-disable'], 'wm')
pi = run / 'fake-pi.sh'
pi.write_text('#!/bin/sh\nprintf "PI_WORKBENCH_READY\\n"\nexec /bin/sleep 300\n')
pi.chmod(0o700)
env = dict(os.environ, AXO_PI_EXECUTABLE=str(pi), AXO_PI_EXTENSION_PATH=str(repository/'crates/axo-server/testdata/pi-extension.js'))
daemon = start([os.environ['AXOD_BINARY'], '--server-dir', str(run/'server'), '--socket', str(ipc),
                '--host-credentials', 'files', '--relay-url', 'http://127.0.0.1:9'], 'daemon', env=env)
try:
    wait('owned daemon ready', lambda: ipc.exists() and rpc(ipc, 'axo.daemon.health', {})['ready'], daemon)
    fixture = shlex.join(['/usr/bin/python3', '-u', str(here/'terminal_fixture.py'), 'fixture.json', '--replay-probe'])
    rpc(ipc, 'axo.config.set', {'key':'shell.command', 'value':fixture})
    sessions = []
    for tag in ['workbench-A', 'workbench-B']:
        folder = run/'home'/tag
        folder.mkdir()
        session = rpc(ipc, 'axo.session.create', {'folder':str(folder)})
        rpc(ipc, 'axo.session.rename', {'sessionId':session['id'], 'name':tag})
        if tag == 'workbench-B':
            pi_shell = next(shell for shell in session['shells'] if shell['role'] == 'pi')
            terminal = next(shell for shell in session['shells'] if shell['role'] == 'terminal')
            rpc(ipc, 'axo.session.layout.set', {'sessionId':session['id'], 'layout':{
                'kind':'split', 'id':'00000000-0000-0000-0000-00000000000b', 'direction':'down', 'ratio':0.35,
                'first':{'kind':'pane','shellId':pi_shell['id']}, 'second':{'kind':'pane','shellId':terminal['id']}}})
        state = folder/'fixture.json'
        wait(f'{tag} fixture', lambda: read(state), daemon)
        sessions.append((tag, session, state))
    diagnostics, picture = run/'workbench.json', run/'workbench.png'
    app = start([str(binary), '--socket', str(ipc), '--diagnostics', str(diagnostics), '--snapshot', str(picture)], 'workbench', cwd=run/'home')
    window = wait('GTK workbench window', lambda: xdo('search','--onlyvisible','--pid',app.pid,'--name','^Axo').splitlines()[0], app)
    xdo('windowactivate', '--sync', window)

    def selected(session):
        data = read(diagnostics)
        expected = {shell['id'] for shell in session['shells']}
        return data if data['sessionId'] == session['id'] and {pane['shellId'] for pane in data['panes'] if pane['ready']} == expected else None

    original_pids = {tag: read(state)['pid'] for tag, _, state in sessions}
    for index, (tag, session, state) in enumerate(sessions + sessions[:1]):
        click_label(app, window, tag)
        data = wait(f'{tag}: both native panes ready', lambda: selected(session), app)
        if tag == 'workbench-B':
            pi_id = next(shell['id'] for shell in session['shells'] if shell['role'] == 'pi')
            terminal_id = next(shell['id'] for shell in session['shells'] if shell['role'] == 'terminal')
            def down_layout():
                grids = {pane['shellId']:pane for pane in read(diagnostics)['panes']}
                return grids[pi_id]['columns'] == grids[terminal_id]['columns'] and grids[pi_id]['rows'] < grids[terminal_id]['rows']
            wait('persisted down-split ratio applied', down_layout, app)
        click_label(app, window, 'Pi', below=80)
        assert 'PI_WORKBENCH_READY' in rendered_text(app, window), 'Pi pane is not the real daemon PTY'
        click_label(app, window, 'Terminal', below=80)
        copied = rendered_text(app, window)
        assert 'GHOSTTY_RENDER_PROBE' in copied
        assert 'REPLAY_LONG_END' in copied.replace('\n','').replace('\r','')
        typed = f'{tag}-{index}'
        xdo('type','--clearmodifiers','--delay','15',typed)
        xdo('key','--clearmodifiers','Return')
        wait('keyboard to selected Session only', lambda: read(state)['input'] == typed, app)
        assert read(state)['pid'] == original_pids[tag]
        terminal = next(shell for shell in session['shells'] if shell['role'] == 'terminal')
        data = selected(session)
        grid = next(pane for pane in data['panes'] if pane['shellId'] == terminal['id'])
        wait('layout viewport matches kernel PTY', lambda: read(state)['columns'] == grid['columns'] and read(state)['rows'] == grid['rows'], app)
    # Catalog refresh preserves the selected view, but discovers newly created Sessions.
    folder = run/'home'/'workbench-C'
    folder.mkdir()
    third = rpc(ipc, 'axo.session.create', {'folder':str(folder)})
    rpc(ipc, 'axo.session.rename', {'sessionId':third['id'], 'name':'workbench-C'})
    click_label(app, window, 'Refresh Sessions')
    wait('new Session appears after native refresh', lambda: find_label(app, 'workbench-C'), app)
    assert selected(sessions[0][1]), 'refresh changed the selected Session'
    original_width = wait('initial workbench snapshot', lambda: GdkPixbuf.Pixbuf.new_from_file(str(picture)).get_width(), app)
    xdo('windowsize', '--sync', window, '1350', '850')
    wait('two pane grids resize', lambda: all(pane['columns'] > next(old['columns'] for old in data['panes'] if old['shellId'] == pane['shellId']) for pane in read(diagnostics)['panes']), app)
    wait('whole workbench snapshot resized', lambda: GdkPixbuf.Pixbuf.new_from_file(str(picture)).get_width() > original_width, app)
    stop(app, window)
    for tag, session, state in sessions:
        assert not read(state)['exited']
        for shell in session['shells']:
            os.kill(shell['processId'], 0)
    assert daemon.poll() is None
    print(json.dumps({'status':'passed', 'checks':['owned real axod catalog', 'native Session sidebar', 'two actual Ghostty panes per persisted right/down layout', 'rendered Pi and terminal replay', 'selection A/B/A detaches without stopping children', 'keyboard routed to selected pane', 'kernel resize matches viewport', 'two pane resize', 'native catalog refresh preserves selection', 'master-fd termios polling', 'clean widget and engine teardown'], 'snapshot':str(picture)}))
finally:
    for process in reversed(processes):
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    for log in logs:
        log.close()
