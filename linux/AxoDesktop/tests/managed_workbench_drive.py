#!/usr/bin/python3
"""Real GTK + real attach admission, on smoke.sh's private HOME/display/bus only.

Pass an isolated runtime containing matching axod/AxoDesktop and lib/share resources.
No proxy, identity override, terminal-content capture, or permissive attach hook.
"""
import os
import pathlib
import runpy
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib

assert os.environ.get('AXO_DESKTOP_ISOLATED') == '1'
binary, root = map(pathlib.Path, sys.argv[1:])
binary = binary.resolve()
repository = pathlib.Path(__file__).resolve().parents[3]
rpc = runpy.run_path(str(repository / 'linux/smoke.py'))['rpc']
socket = root / 'server/axod.sock'
log = (root / 'managed-daemon.log').open('w')
wm = subprocess.Popen(['openbox', '--sm-disable'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pi = root / 'owned-pi'
pi.write_text('#!/bin/sh\nprintf "OWNED PI FIXTURE\\n"\nexec /bin/sleep 300\n')
pi.chmod(0o700)
env = dict(os.environ, AXO_PI_EXECUTABLE=str(pi), RUST_LOG='axo_server=debug', GTK_A11Y='atspi')
daemon = subprocess.Popen([str(binary.parent/'axod'), '--socket', str(socket),
    '--server-dir', str(root/'server'), '--host-credentials', 'files', '--relay-url', 'http://127.0.0.1:9'],
    env=env, stdout=log, stderr=log)

def wait(description, check):
    end = time.monotonic() + 25
    while time.monotonic() < end:
        assert daemon.poll() is None, 'owned daemon exited'
        try:
            result = check()
            if result:
                return result
        except (OSError, RuntimeError, GLib.Error):
            pass
        time.sleep(.05)
    raise AssertionError(f'timed out: {description}; logs in {root}')

def labels(pid):
    desktop = Atspi.get_desktop(0)
    pending = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    pending = [app for app in pending if app and app.get_process_id() == pid]
    found = []
    while pending:
        node = pending.pop()
        if node is None:
            continue
        found.append(node)
        pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))
    return found

def create(name):
    folder = root/'home'/name
    folder.mkdir()
    session = rpc(socket, 'axo.session.create', {'folder':str(folder)})
    rpc(socket, 'axo.session.rename', {'sessionId':session['id'], 'name':name})
    return session

def attached(session):
    text = (root/'server/stderr.log').read_text()
    return all(any('event=session.attach_ready' in line and f'shell_id={shell["id"]} ' in line
        for line in text.splitlines()) for shell in session['shells'])

try:
    wait('owned daemon ready', lambda: socket.exists() and rpc(socket, 'axo.daemon.health', {})['ready'])
    rpc(socket, 'axo.config.set', {'key':'shell.command','value':str(pi)})
    existing = create('existing-owned')
    # Exercise the actual unmanaged-launcher handoff, not just a direct broker call.
    subprocess.run([str(binary),'--socket',str(socket)], check=True, timeout=15)
    pid = rpc(socket, 'axo.client.desktop.open', {})['processId']
    assert rpc(socket, 'axo.client.desktop.open', {})['processId'] == pid
    wait('both existing panes attached with the production guard', lambda: attached(existing))
    wait('native GTK pane groups', lambda: {'Pi pane','Terminal pane'}.issubset({node.name for node in labels(pid)}))
    fresh = create('new-owned')
    row = wait('new Session in the live sidebar', lambda: next((node for node in labels(pid) if node.name=='new-owned'),None))
    window = subprocess.check_output(['xdotool','search','--onlyvisible','--pid',str(pid),'--name','^Axo'],text=True).splitlines()[0]
    subprocess.run(['xdotool','windowactivate','--sync',window],check=True)
    def allocated_row():
        rectangle = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        return rectangle if rectangle.width>0 and rectangle.height>0 else None
    rectangle = wait('allocated new Session row',allocated_row)
    subprocess.run(['xdotool','mousemove','--window',window,str(rectangle.x+max(5,rectangle.width//2)),str(rectangle.y+rectangle.height//2),'click','1'],check=True)
    wait('both new Session panes attached',lambda: attached(fresh))
    assert not any('Cannot attach' in (node.name or '') for node in labels(pid))
    assert 'reason=not_allowed' not in (root/'server/stderr.log').read_text()
    ready_before = (root/'server/stderr.log').read_text().count('event=session.attach_ready')
    close = wait('native Close button',lambda: next((node for node in labels(pid) if node.name=='Close'),None))
    close_rect = close.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool','mousemove','--window',window,str(close_rect.x+close_rect.width//2),str(close_rect.y+close_rect.height//2),'click','1'],check=True)
    wait('native workbench shutdown', lambda: 'clean shutdown; terminal widgets released' in (root/'server/stderr.log').read_text())
    subprocess.run([str(binary),'--socket',str(socket)], check=True, timeout=15)
    reopened = rpc(socket, 'axo.client.desktop.open', {})['processId']
    assert reopened != pid, 'closed workbench identity was reused'
    wait('reopened panes attach with a fresh identity', lambda: (root/'server/stderr.log').read_text().count('event=session.attach_ready') >= ready_before+2)
    print('Managed GTK workbench: existing/new Sessions, both panes, launcher handoff, singleton, and reopen passed.')
finally:
    daemon.terminate()
    try:
        daemon.wait(timeout=10)
    except subprocess.TimeoutExpired:
        daemon.kill()
        daemon.wait(timeout=5)
    wm.terminate()
    wm.wait(timeout=5)
    log.close()
