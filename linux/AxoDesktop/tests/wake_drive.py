#!/usr/bin/python3
"""Foreground dormant wake with an owned cold-restored axod and its wire-level fake Pi."""
import json
import os
import pathlib
import runpy
import shlex
import signal
import sqlite3
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
auto = 'axo.session.pi.restart.auto.v1'
processes, logs = [], []
proxy = None


def start(command, name, **options):
    log = (run/f'{name}.log').open('w')
    logs.append(log)
    process = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True, **options)
    processes.append(process)
    return process


def wait(description, check, process, timeout=25):
    end = time.monotonic()+timeout
    while time.monotonic() < end:
        if process.poll() is not None:
            raise RuntimeError(f'{description}: exited {process.returncode}; {run}')
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, KeyError, IndexError, GLib.Error, subprocess.CalledProcessError):
            pass
        time.sleep(.05)
    root = Atspi.get_desktop(0)
    pending = [root.get_child_at_index(i) for i in range(root.get_child_count())]
    names = []
    while pending:
        node = pending.pop()
        if node is None:
            continue
        try:
            name = node.get_name()
            if name:
                names.append(name)
            pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))
        except GLib.Error:
            pass
    (run/'wake-failure.json').write_text(json.dumps({'names':names,'methods':proxy.methods if proxy else [],'errors':proxy.errors if proxy else []}))
    raise RuntimeError(f'timed out: {description}; {run}')


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str,args)], text=True, stderr=subprocess.PIPE).strip()


def find(app, text, prefix=False):
    root = Atspi.get_desktop(0)
    pending = [root.get_child_at_index(i) for i in range(root.get_child_count())]
    pending = [node for node in pending if node is not None and node.get_process_id() == app.pid]
    while pending:
        node = pending.pop()
        if node is None:
            continue
        try:
            name = node.get_name() or ''
            if node.get_state_set().contains(Atspi.StateType.SHOWING) and (name.startswith(text) if prefix else name == text):
                return node
            pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))
        except GLib.Error:
            pass


def select(app, name):
    node = wait(f'Session row {name}', lambda: find(app,name), app)
    while node.get_role() != Atspi.Role.LIST_ITEM:
        node = node.get_parent()
    selection = node.get_parent().get_selection_iface()
    assert selection is not None and selection.select_child(node.get_index_in_parent())


def catalog():
    return rpc(ipc,'axo.session.catalog',{})['sessions']


def current(record):
    return next(item for item in catalog() if item['id'] == record['id'])


def pi(record):
    return next(pane for pane in record['shells'] if pane['role'] == 'pi')


start(['openbox','--sm-disable'],'wm')
fixture_pi = repository/'bazel-bin/crates/axod/fake_pi'
assert fixture_pi.is_file(), 'build //crates/axod:fake_pi with Bazel first'
env = dict(os.environ, AXO_PI_EXECUTABLE=str(fixture_pi),
           AXO_PI_EXTENSION_PATH=str(repository/'crates/axo-server/testdata/pi-extension.js'),
           AXO_FAKE_PI_STARTUP_MS='20', AXO_FAKE_PI_LOG=str(run/'fake-pi.log'))
command = [os.environ['AXOD_BINARY'],'--server-dir',str(run/'server'),'--socket',str(ipc),
           '--host-credentials','files','--relay-url','http://127.0.0.1:9']
daemon = start(command,'daemon-seed',env=env)
try:
    wait('owned daemon ready',lambda:ipc.exists() and rpc(ipc,'axo.daemon.health',{})['ready'],daemon)
    terminal = run/'owned-terminal.sh'
    terminal.write_text('#!/bin/sh\nexec '+shlex.join(['/usr/bin/python3','-u',str(here/'terminal_fixture.py')])+' "$HOME/wake-$$.json"\n')
    terminal.chmod(0o700)
    rpc(ipc,'axo.config.set',{'key':'shell.command','value':str(terminal)})
    records = []
    for tag in ['wake-A','wake-B','wake-C','wake-D','wake-E']:
        folder = run/'home'/tag
        folder.mkdir()
        record = rpc(ipc,'axo.session.create',{'folder':str(folder)})
        rpc(ipc,'axo.session.rename',{'sessionId':record['id'],'name':tag})
        wait('owned fake Pi bridge binds',lambda:current(record).get('piSessionId'),daemon)
        rpc(ipc,'axo.session.prompt',{'sessionId':record['id'],'text':'owned fixture seed','delivery':'followUp'})
        # The fake creates its transcript header on its first turn, unlike real Pi.
        wait('owned resumable fake transcript',lambda:pathlib.Path(record['piSessionFile']).is_file() and current(record)['status']=='ready',daemon)
        records.append(record)
    daemon.terminate()
    assert daemon.wait(timeout=10) == 0
    # Only this stopped owned database is aged; no paired data or transcripts are read.
    with sqlite3.connect(run/'server/axo.db') as database:
        old = int(time.time())-7200
        database.executemany('UPDATE sessions SET created_at=?,last_message_at=0 WHERE id=?',[(old+index,record['id']) for index,record in enumerate(records[1:])])
        # Shared order is created_at ascending: B is initially selected, but the
        # catalog will arrive only after Settings has made the main window inactive.
        database.execute('UPDATE sessions SET created_at=?,last_message_at=? WHERE id=?',(old,int(time.time()),records[0]['id']))
        database.execute('UPDATE sessions SET created_at=? WHERE id=?',(old-1,records[1]['id']))
    daemon = start(command,'daemon-restored',env=env)
    wait('cold-restored fixture ready',lambda:rpc(ipc,'axo.daemon.health',{})['ready'],daemon)
    records = [current(record) for record in records]
    assert pi(records[0])['available']
    assert all(pi(record).get('dormant') and pi(record)['processId'] == 0 for record in records[1:])
    terminals = {record['id']:next(pane['processId'] for pane in record['shells'] if pane['role']=='terminal') for record in records}
    active_pi = pi(records[0])['processId']
    proxy = OwnedProxy(run,ipc,allow_actions={auto})
    proxy.catalog_gate.clear()
    diagnostics = run/'wake.json'
    app_command = [str(binary),'--socket',str(proxy.rpc_path),'--diagnostics',str(diagnostics)]
    if os.environ.get('AXO_DESKTOP_TRACE') == '1':
        app_command = ['strace','-D','-ff','-e','trace=ioctl,close','-o',str(run/'native.trace'),*app_command]
    app = start(app_command,'wake',cwd=run/'home')
    window = wait('workbench',lambda:xdo('search','--all','--onlyvisible','--pid',app.pid,'--name','^Axo').splitlines()[0],app)
    xdo('windowactivate','--sync',window)

    def data():
        return json.loads(diagnostics.read_text())
    def selected(record):
        snapshot = data()
        expected = {pane['id'] for pane in current(record)['shells'] if pane['available']}
        return snapshot if snapshot['sessionId']==record['id'] and {pane['shellId'] for pane in snapshot['panes'] if pane['ready']}==expected else None
    def count():
        with proxy.lock:
            return len(proxy.wake_requests)
    def settings():
        xdo('key','--clearmodifiers','ctrl+comma')
        return wait('settings foreground',lambda:xdo('search','--all','--onlyvisible','--pid',app.pid,'--name','^Axo Settings$').splitlines()[0],app)

    assert count()==0
    assert all(pi(current(record)).get('dormant') for record in records[1:]), 'background catalog woke Pi'
    settings_window = settings()
    xdo('windowactivate','--sync',settings_window)
    proxy.catalog_gate.set()
    wait('dormant B projected behind Settings',lambda:selected(records[1]),app)
    assert xdo('getactivewindow') == settings_window
    time.sleep(.2)
    assert count()==0 and pi(current(records[1])).get('dormant')
    dormant_view = data()
    terminal_id = next(pane['id'] for pane in records[1]['shells'] if pane['role']=='terminal')
    terminal_generation = next(pane['paneGeneration'] for pane in dormant_view['panes'] if pane['shellId']==terminal_id)
    with proxy.lock:
        terminal_attaches = proxy.attach_requests.count(terminal_id)
    xdo('windowactivate','--sync',settings_window)
    xdo('key','--clearmodifiers','alt+F4')
    wait('foreground selection wakes B',lambda:pi(current(records[1]))['available'] and selected(records[1]),app)
    assert count()==1
    assert data()['viewGeneration']==dormant_view['viewGeneration'], 'Pi wake rebuilt its sibling Scene'
    assert next(pane['paneGeneration'] for pane in data()['panes'] if pane['shellId']==terminal_id)==terminal_generation
    with proxy.lock:
        assert proxy.attach_requests.count(terminal_id)==terminal_attaches, 'healthy terminal was reattached'
    assert all(pi(current(record)).get('dormant') for record in records[2:])
    xdo('type','--clearmodifiers','foreground-wake-terminal')
    xdo('key','--clearmodifiers','Return')
    state = run/'home'/f"wake-{terminals[records[1]['id']]}.json"
    wait('wake preserves terminal focus rather than stealing input to Pi',lambda:json.loads(state.read_text())['input']=='foreground-wake-terminal',app)

    proxy.wake_gate.clear()
    select(app,'wake-C')
    wait('admitted C wake while acknowledgement held',lambda:pi(current(records[2]))['available'] and selected(records[2]),app)
    assert count()==2
    select(app,'wake-A')
    wait('newer selection A',lambda:selected(records[0]),app)
    proxy.wake_gate.set()
    time.sleep(.3)
    assert selected(records[0]) and count()==2, 'late wake reply selected its old target'

    proxy.lose_wake_ack = True
    select(app,'wake-D')
    wait('lost admitted wake reply reconciled from catalog',lambda:pi(current(records[3]))['available'] and selected(records[3]),app)
    assert count()==3
    epoch = data()['catalogEpoch']
    proxy.cut('rpc')
    wait('read reconnect does not replay wake',lambda:data()['catalogEpoch']>epoch and selected(records[3]),app)
    xdo('windowactivate','--sync',window)
    assert count()==3
    proxy.lose_wake_ack = False

    proxy.hidden_methods.add(auto)
    select(app,'wake-E')
    wait('unsupported auto wake explicitly shown',lambda:find(app,'Pi wake was not sent:',prefix=True),app)
    assert count()==3 and pi(current(records[4])).get('dormant')
    settings_window = settings()
    xdo('windowactivate','--sync',settings_window)
    xdo('key','--clearmodifiers','alt+F4')
    time.sleep(.2)
    assert count()==3, 'unsupported auto wake retried on focus transition'
    proxy.hidden_methods.clear()
    button = wait('explicit unavailable-only wake button',lambda:find(app,'Wake Pi'),app)
    action = button.get_action_iface()
    assert action is not None and action.do_action(0)
    wait('explicit new wake intent after unsupported preflight',lambda:pi(current(records[4]))['available'] and selected(records[4]),app)
    assert count()==4
    with proxy.lock:
        assert [item['sessionId'] for item in proxy.wake_requests] == [record['id'] for record in records[1:]]
    live_log = (run/'wake.log').read_text()
    assert 'error getting termios mode' not in live_log, 'live surface queried a non-TTY descriptor'
    # Same-layout Pi exit/recovery must replace only that slot. Hold one attach
    # through another replacement, proving its late result cannot install stale IO.
    stable = data()
    pi_id = pi(current(records[4]))['id']
    terminal_e = next(pane['id'] for pane in records[4]['shells'] if pane['role']=='terminal')
    stable_terminal = next(pane['paneGeneration'] for pane in stable['panes'] if pane['shellId']==terminal_e)
    with proxy.lock:
        stable_attaches = proxy.attach_requests.count(terminal_e)
    terminal_node = wait('stable terminal pane',lambda:find(app,'Terminal pane'),app)
    bounds = terminal_node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('mousemove','--window',window,bounds.x+bounds.width//2,bounds.y+min(80,bounds.height//2))
    xdo('click','1')
    def stop_owned_pi():
        pid = pi(current(records[4]))['processId']
        assert pathlib.Path(f'/proc/{pid}/exe').resolve() == fixture_pi.resolve()
        os.kill(pid,signal.SIGTERM)
        wait('owned Pi exit projected without sibling teardown',lambda:not pi(current(records[4]))['available'] and selected(records[4]),app)
        assert data()['viewGeneration']==stable['viewGeneration']
        assert next(pane['paneGeneration'] for pane in data()['panes'] if pane['shellId']==terminal_e)==stable_terminal
    stop_owned_pi()
    proxy.attach_gate.clear()
    with proxy.lock:
        previous_pi_attaches = proxy.attach_requests.count(pi_id)
    rpc(ipc,auto,{'sessionId':records[4]['id'],'shellId':pi_id})
    wait('first replacement attach held',lambda:proxy.attach_requests.count(pi_id)>previous_pi_attaches,app)
    stop_owned_pi()
    rpc(ipc,auto,{'sessionId':records[4]['id'],'shellId':pi_id})
    wait('current replacement attach held',lambda:proxy.attach_requests.count(pi_id)>previous_pi_attaches+1,app)
    proxy.attach_gate.set()
    wait('only current replacement installs',lambda:pi(current(records[4]))['available'] and selected(records[4]),app)
    wait('cancelled attachment released',lambda:proxy.count('attach')==2,app)
    assert data()['viewGeneration']==stable['viewGeneration']
    assert next(pane['paneGeneration'] for pane in data()['panes'] if pane['shellId']==terminal_e)==stable_terminal
    with proxy.lock:
        assert proxy.attach_requests.count(terminal_e)==stable_attaches, 'Pi replacement recreated its healthy terminal'
    xdo('type','--clearmodifiers','pane-stability-after-restart')
    xdo('key','--clearmodifiers','Return')
    state_e = run/'home'/f"wake-{terminals[records[4]['id']]}.json"
    wait('stable terminal retains keyboard focus',lambda:json.loads(state_e.read_text())['input']=='pane-stability-after-restart',app)
    assert count()==4, 'unavailable Pi was implicitly recovered by UI'
    for record in records:
        assert next(pane['processId'] for pane in current(record)['shells'] if pane['role']=='terminal') == terminals[record['id']]
    assert pi(current(records[0]))['processId'] == active_pi
    assert not proxy.errors,proxy.errors
    xdo('windowactivate','--sync',window)
    xdo('key','--clearmodifiers','alt+F4')
    assert app.wait(timeout=8)==0
    log = (run/'wake.log').read_text()
    assert 'clean shutdown; terminal widgets released' in log and 'CRITICAL' not in log
    retired_log = log[len(live_log):]
    mode_errors = [line for line in retired_log.splitlines() if 'error getting termios mode' in line]
    assert all('err=error.GetModeFailed' in line for line in mode_errors), mode_errors
    # A final poll can race confirmed-exit N_NULL retirement. strace proved TCGETS2
    # success -> EINVAL on that same master (not ENOTTY/EBADF). Keep the live-phase
    # assertion above; optional trace mode also verifies the raw retired-master errno.
    if os.environ.get('AXO_DESKTOP_TRACE') == '1':
        failures = [line for trace in run.glob('native.trace.*') for line in trace.read_text().splitlines()
                    if 'TCGETS2' in line and '= -1' in line and not line.startswith('ioctl(2,')]
        assert all('EINVAL' in line or 'EIO' in line for line in failures), failures
    assert all(pi(current(record))['available'] for record in records)
    print(json.dumps({'status':'passed','checks':['owned cold restore leaves old Pis dormant','background catalog does not wake','catalog selection behind Settings does not wake','foreground selected Pi wakes once','terminal focus/input and child PIDs preserved','late wake cannot steal newer selection','admitted wake lost ack/read reconnect never replays','unsupported auto method never falls back to force','explicit new wake intent','unchanged-layout healthy native pane survives Pi exit/recovery', 'superseded attach cannot install stale IO', 'quit detaches without stopping children']}))
finally:
    if proxy is not None:
        proxy.close()
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL)
                process.wait()
    for log in logs:
        log.close()
