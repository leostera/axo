#!/usr/bin/python3
"""Owned axod/catalog -> two real Ghostty panes; private Xvfb/D-Bus/HOME only."""
import json
import math
import os
import sqlite3
import struct
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
proxy = None


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
        except (OSError, ValueError, KeyError, IndexError, GLib.Error, sqlite3.Error, subprocess.CalledProcessError):
            pass
        time.sleep(0.05)
    raise RuntimeError(f'timed out: {description}; {run}')


def read(path):
    return json.loads(path.read_text())


def native_grids(viewport, layout):
    scale = viewport['backingScale']
    native = viewport['rasterization']
    padding = native['paddingPixels']
    cell = viewport['cell']
    divider = viewport['dividerThickness']
    rounded = lambda n: math.floor(n + .5) if n >= 0 else math.ceil(n - .5)
    f32 = lambda n: struct.unpack('f', struct.pack('f', n))[0]
    result = {}
    def visit(node, width, height, x, y):
        if node['kind'] == 'pane':
            pixels_w = rounded((x + width) * scale) - rounded(x * scale)
            pixels_h = rounded((y + height) * scale) - rounded(y * scale)
            columns = int(f32(f32(max(0, pixels_w - padding['left'] - padding['right'])) / f32(cell['width'])))
            rows = int(f32(f32(max(0, pixels_h - padding['top'] - padding['bottom'])) / f32(cell['height'])))
            result[node['shellId']] = (max(1, min(65535, rows)), max(1, min(65535, columns)))
        else:
            horizontal = node['direction'] == 'right'
            available = max(0, (width if horizontal else height) - divider)
            first = math.floor(available * min(.99, max(.01, node['ratio'])))
            second = available - first
            visit(node['first'], first if horizontal else width, height if horizontal else first, x, y)
            visit(node['second'], second if horizontal else width, height if horizontal else second,
                  x + first + divider if horizontal else x, y if horizontal else y + first + divider)
    visit(layout, viewport['terminalArea']['width'], viewport['terminalArea']['height'],
          native['origin']['x'], native['origin']['y'])
    return result


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str, args)], text=True, stderr=subprocess.PIPE).strip()


def find_label(app, text):
    desktop = Atspi.get_desktop(0)
    apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    pending = [node for node in apps if node is not None and node.get_process_id() == app.pid]
    while pending:
        node = pending.pop()
        if node is None:
            continue  # Live catalog updates can remove an AT-SPI child during traversal.
        try:
            name = node.get_name() or ''
            if (node.get_role() in [Atspi.Role.LABEL, Atspi.Role.PUSH_BUTTON] or name in ['Pi pane', 'Terminal pane']) and (name == text or name.endswith(' ' + text) or node.get_description() == text):
                return node
            pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))
        except GLib.Error:
            continue


def pane_group_count(app):
    desktop = Atspi.get_desktop(0)
    pending = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    pending = [node for node in pending if node is not None and node.get_process_id() == app.pid]
    count = 0
    while pending:
        node = pending.pop()
        if node is None:
            continue
        try:
            count += node.get_name() in ['Pi pane', 'Terminal pane']
            pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))
        except GLib.Error:
            continue
    return count


def click_label(app, window, text, below=0):
    node = wait(f'accessible label {text}', lambda: find_label(app, text), app)
    rect = node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('mousemove', '--window', window, rect.x + max(5, rect.width // 2), rect.y + rect.height // 2 + below)
    xdo('click', '1')


def click_pane(app, window, name):
    node = wait(f'accessible pane {name}', lambda: find_label(app, name), app)
    rect = node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    assert rect.width > 100 and rect.height > 100
    xdo('mousemove', '--window', window, rect.x + rect.width // 2, rect.y + 80)
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
    click_label(app, window, 'Close')  # Real native window control, not just a shortcut.
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
        session = next(record for record in rpc(ipc, 'axo.session.catalog', {})['sessions'] if record['id'] == session['id'])
        sessions.append((tag, session, state))
    diagnostics, picture = run/'workbench.json', run/'workbench.png'
    frontend_socket = ipc
    if os.environ.get('AXO_DESKTOP_RECONNECT_TEST') == '1':
        from reconnect_proxy import OwnedProxy
        proxy = OwnedProxy(run, ipc)
        frontend_socket = proxy.rpc_path
    app = start([str(binary), '--socket', str(frontend_socket), '--diagnostics', str(diagnostics), '--snapshot', str(picture)], 'workbench', cwd=run/'home')
    window = wait('GTK workbench window', lambda: xdo('search','--onlyvisible','--pid',app.pid,'--name','^Axo').splitlines()[0], app)
    xdo('windowactivate', '--sync', window)
    caption = wait('compact sidebar caption', lambda: find_label(app, 'Sessions'), app)
    sidebar_bounds = wait('allocated sidebar', lambda: (bounds if (bounds := caption.get_component_iface().get_extents(Atspi.CoordType.WINDOW)).width > 0 else None), app)
    assert sidebar_bounds.width <= 220, 'sidebar expanded with its header/footer controls'

    def selected(session):
        data = read(diagnostics)
        expected = {shell['id'] for shell in session['shells']}
        return data if data['sessionId'] == session['id'] and {pane['shellId'] for pane in data['panes'] if pane['ready']} == expected else None

    original_pids = {tag: read(state)['pid'] for tag, _, state in sessions}
    for index, (tag, session, state) in enumerate(sessions + sessions[:1]):
        click_label(app, window, tag)
        data = wait(f'{tag}: both native panes ready', lambda: selected(session), app)
        wait('exactly two native pane groups', lambda: pane_group_count(app) == 2, app)
        if tag == 'workbench-B':
            pi_id = next(shell['id'] for shell in session['shells'] if shell['role'] == 'pi')
            terminal_id = next(shell['id'] for shell in session['shells'] if shell['role'] == 'terminal')
            def down_layout():
                grids = {pane['shellId']:pane for pane in read(diagnostics)['panes']}
                return grids[pi_id]['columns'] == grids[terminal_id]['columns'] and grids[pi_id]['rows'] < grids[terminal_id]['rows']
            wait('persisted down-split ratio applied', down_layout, app)
        pane = wait('named full-height pane', lambda: find_label(app, 'Pi pane'), app)
        assert pane.get_component_iface().get_extents(Atspi.CoordType.WINDOW).y <= 2, 'terminal pushed down by a full-width toolbar'
        assert find_label(app, 'Pi') is None and find_label(app, 'Terminal') is None, 'visible pane captions waste terminal space'
        row = wait('dense Session row', lambda: find_label(app, tag), app)
        for _ in range(6):
            if row.get_role() == Atspi.Role.LIST_ITEM:
                break
            row = row.get_parent()
        assert row.get_role() == Atspi.Role.LIST_ITEM
        assert 0 < row.get_component_iface().get_extents(Atspi.CoordType.WINDOW).height <= 22
        click_pane(app, window, 'Pi pane')
        assert 'PI_WORKBENCH_READY' in rendered_text(app, window), 'Pi pane is not the real daemon PTY'
        click_pane(app, window, 'Terminal pane')
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
    # Live updates discover new Sessions without a manual refresh or view replacement.
    generation = read(diagnostics)['viewGeneration']
    folder = run/'home'/'workbench-C'
    folder.mkdir()
    third = rpc(ipc, 'axo.session.create', {'folder':str(folder)})
    rpc(ipc, 'axo.session.rename', {'sessionId':third['id'], 'name':'workbench-C'})
    wait('new Session appears live', lambda: find_label(app, 'workbench-C'), app)
    assert selected(sessions[0][1]), 'live update changed the selected Session'
    assert read(diagnostics)['viewGeneration'] == generation, 'unrelated Session recreated selected panes'
    rpc(ipc, 'axo.session.rename', {'sessionId':sessions[0][1]['id'], 'name':'workbench-A-live'})
    wait('live rename', lambda: find_label(app, 'workbench-A-live'), app)
    assert read(diagnostics)['viewGeneration'] == generation, 'rename recreated terminal widgets'
    rpc(ipc, 'axo.session.rename', {'sessionId':sessions[0][1]['id'], 'name':'workbench-A'})
    wait('live rename restored', lambda: find_label(app, 'workbench-A'), app)
    click_label(app, window, 'Refresh Sessions')
    rpc(ipc, 'axo.session.rename', {'sessionId':third['id'], 'name':'workbench-C-refreshed'})
    wait('refresh and event update settle', lambda: find_label(app, 'workbench-C-refreshed'), app)
    assert read(diagnostics)['viewGeneration'] == generation, 'healthy refresh recreated terminal widgets'
    rpc(ipc, 'axo.session.close', {'sessionId':third['id']})
    wait('externally archived Session disappears live', lambda: find_label(app, 'workbench-C-refreshed') is None, app)
    assert read(diagnostics)['viewGeneration'] == generation, 'unrelated removal recreated selected panes'

    if proxy:
        counts = {tag: read(state)['inputCount'] for tag, _, state in sessions}
        before = read(diagnostics)
        viewport_sends = proxy.methods.count('axo.client.viewport.set.v2')
        proxy.available = False
        proxy.cut('rpc')
        wait('offline view is detached', lambda: find_label(app, 'Daemon disconnected. Reconnecting…'), app)
        xdo('type', '--clearmodifiers', '--delay', '5', 'MUST_NOT_REPLAY')
        xdo('key', '--clearmodifiers', 'Return')
        proxy.available = True
        wait('catalog reconnect installs fresh epoch and selected view', lambda:
             selected(sessions[0][1]) and read(diagnostics)['catalogEpoch'] > before['catalogEpoch']
             and read(diagnostics)['viewGeneration'] > before['viewGeneration'], app)
        if os.environ.get('AXO_DESKTOP_VIEWPORT_TEST') == '1':
            wait('viewport republished after reconnect epoch', lambda: proxy.methods.count('axo.client.viewport.set.v2') > viewport_sends, app)
        before = read(diagnostics)
        proxy.cut('attach')
        wait('Ghostty EOF reconnects output without resetting catalog', lambda:
             selected(sessions[0][1]) and read(diagnostics)['viewGeneration'] > before['viewGeneration'], app)
        assert read(diagnostics)['catalogEpoch'] == before['catalogEpoch']
        wait('exactly two panes after EOF retry', lambda: pane_group_count(app) == 2, app)
        # Hold an attachment handshake, switch selection, then release its stale completion.
        proxy.attach_gate.clear()
        opened = proxy.opened['attach']
        before_pending = read(diagnostics)['viewGeneration']
        click_label(app, window, 'workbench-B')
        wait('owned pending attachments', lambda: proxy.opened['attach'] > opened, app)
        click_label(app, window, 'workbench-A')
        proxy.attach_gate.set()
        wait('new selection owns both panes after late old attach', lambda:
             selected(sessions[0][1]) and read(diagnostics)['viewGeneration'] > before_pending, app)
        wait('exactly two panes after late attachment', lambda: pane_group_count(app) == 2, app)
        click_pane(app, window, 'Terminal pane')
        assert 'GHOSTTY_RENDER_PROBE' in rendered_text(app, window)
        for tag, _, state in sessions:
            assert read(state)['pid'] == original_pids[tag], 'transport retry restarted a child'
            assert read(state)['inputCount'] == counts[tag], 'transport retry replayed input'
        assert not proxy.errors, proxy.errors
    data = selected(sessions[0][1])
    original_width = wait('initial workbench snapshot', lambda: GdkPixbuf.Pixbuf.new_from_file(str(picture)).get_width(), app)
    xdo('windowsize', '--sync', window, '1350', '850')
    wait('two pane grids resize', lambda: all(pane['columns'] > next(old['columns'] for old in data['panes'] if old['shellId'] == pane['shellId']) for pane in read(diagnostics)['panes']), app)
    wait('whole workbench snapshot resized', lambda: GdkPixbuf.Pixbuf.new_from_file(str(picture)).get_width() > original_width, app)
    # Review settled chrome, not Ghostty's transient native resize indicator.
    settled = time.time() + 0.8
    wait('settled workbench snapshot', lambda: picture.stat().st_mtime > settled, app)
    if os.environ.get('AXO_DESKTOP_VIEWPORT_TEST') == '1':
        def stored_native():
            with sqlite3.connect('file:' + str(run/'server/axo.db') + '?mode=ro', uri=True) as database:
                rows = database.execute("SELECT key,value FROM daemon_metadata WHERE key IN ('client_viewport','client_viewport_native_v2')").fetchall()
            values = {key:json.loads(value) for key,value in rows}
            assert 'rasterization' not in values['client_viewport'], 'old-reader key contains new fields'
            return values['client_viewport_native_v2']
        viewport = wait('actual native metrics persisted', lambda: (value if (value := stored_native()) == read(diagnostics)['viewport'] else None), app)
        hidden = sessions[1]
        expected = native_grids(viewport, hidden[1]['layout'])
        terminal = next(shell for shell in hidden[1]['shells'] if shell['role'] == 'terminal')
        wait('unattached terminal pre-sized from actual renderer metrics', lambda:
             (read(hidden[2])['rows'], read(hidden[2])['columns']) == expected[terminal['id']], app)
        click_label(app, window, hidden[0])
        def projected_visible():
            visible = selected(hidden[1])
            return visible if visible and {pane['shellId']:(pane['rows'],pane['columns']) for pane in visible['panes']} == expected else None
        # Core-ready precedes GTK's persisted split allocation. Wait for the exact final
        # grids, not just the first frame at the Paned widget's provisional 50/50 position.
        visible = wait('hidden Session settles at its exact projected grids', projected_visible, app)
        click_label(app, window, 'workbench-A')
        wait('selected Session restored for new-pane test', lambda: selected(sessions[0][1]), app)
        viewport = wait('native metrics settled after selection', lambda: (value if (value := stored_native()) == read(diagnostics)['viewport'] else None), app)
        folder = run/'home'/'viewport-new'
        folder.mkdir()
        created = rpc(ipc, 'axo.session.create', {'folder':str(folder)})
        expected_new = native_grids(viewport, created['layout'])
        terminal = next(shell for shell in created['shells'] if shell['role'] == 'terminal')
        wait('new unattached Session terminal has the projected grid', lambda:
             (read(folder/'fixture.json')['rows'],read(folder/'fixture.json')['columns']) == expected_new[terminal['id']], app)
        # Lose an admitted geometry write's reply without touching the catalog stream.
        proxy.lose_viewport_ack = True
        sends = proxy.methods.count('axo.client.viewport.set.v2')
        xdo('windowsize', '--sync', window, '1390', '870')
        wait('uncertain viewport shown honestly', lambda: find_label(app, 'Viewport unconfirmed; Refresh to retry'), app)
        assert proxy.methods.count('axo.client.viewport.set.v2') == sends + 1
        xdo('windowsize', '--sync', window, '1420', '890')
        time.sleep(.35)
        assert proxy.methods.count('axo.client.viewport.set.v2') == sends + 1, 'geometry change retried an uncertain write'
        proxy.lose_viewport_ack = False
        click_label(app, window, 'Refresh Sessions')
        wait('explicit viewport retry writes the newest geometry', lambda:
             proxy.methods.count('axo.client.viewport.set.v2') == sends + 2 and stored_native() == read(diagnostics)['viewport'], app)
        wait('uncertainty cleared only after acknowledgement', lambda: find_label(app, 'Viewport unconfirmed; Refresh to retry') is None, app)
        assert not proxy.errors, proxy.errors
    stop(app, window)
    if proxy:
        wait('catalog/attachment connections released on quit', lambda: proxy.count('rpc') == 0 and proxy.count('attach') == 0, daemon)
        assert not proxy.errors, proxy.errors
    for tag, session, state in sessions:
        assert not read(state)['exited']
        for shell in session['shells']:
            os.kill(shell['processId'], 0)
    assert daemon.poll() is None
    print(json.dumps({'status':'passed', 'checks':['owned real axod catalog', 'compact fixed-width Session sidebar, 22px rows and caption-free accessible panes', 'two actual Ghostty panes per persisted right/down layout', 'rendered Pi and terminal replay', 'selection A/B/A detaches without stopping children', 'keyboard routed to selected pane', 'kernel resize matches viewport', 'two pane resize', 'live catalog create/rename/remove without replacing selected panes', 'explicit refresh preserves selection', 'isolated RPC and attachment EOF recovery, stale attach cancellation and no input replay' if proxy else 'detach-only selection', 'master-fd termios polling', 'native viewport persistence, hidden/new panes and uncertain-write fence' if os.environ.get('AXO_DESKTOP_VIEWPORT_TEST') == '1' else 'actual attached-surface resize', 'clean widget and engine teardown'], 'snapshot':str(picture)}))
finally:
    if proxy:
        proxy.close()
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
