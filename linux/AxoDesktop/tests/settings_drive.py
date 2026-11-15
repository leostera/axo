#!/usr/bin/python3
"""Settings UX against an owned real daemon, then a lost-ack protocol fixture."""
import json
import os
import pathlib
import runpy
import signal
import socket
import subprocess
import sys
import threading
import time
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib

if os.environ.get('AXO_DESKTOP_ISOLATED') != '1':
    raise SystemExit('use the private desktop launcher')
binary, run = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2])
here = pathlib.Path(__file__).resolve().parent
repo = here.parents[2]
rpc = runpy.run_path(str(repo/'linux/smoke.py'))['rpc']
processes, logs = [], []


def start(command, name, **options):
    log = (run/f'{name}.log').open('w')
    logs.append(log)
    process = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True, **options)
    processes.append(process)
    return process


def wait(description, check, process, timeout=20):
    end = time.monotonic()+timeout
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
    raise RuntimeError(f'timed out: {description}; {run}')


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str,args)], text=True, stderr=subprocess.PIPE).strip()


def walk(nodes):
    pending=list(nodes)
    while pending:
        node=pending.pop()
        yield node
        pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))


def children(app):
    desktop=Atspi.get_desktop(0)
    apps=[desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    # The workbench also has a Sessions label. Bind actions to this window, not
    # whichever identically named node happens to be last in the app's tree.
    root=next((node for node in walk(node for node in apps if node.get_process_id()==app.pid)
               if node.get_name()=='Axo Settings' and node.get_state_set().contains(Atspi.StateType.SHOWING)),None)
    if root:
        yield from walk([root])


def find(app, name):
    for node in children(app):
        if (node.get_name()==name or node.get_description()==name) and node.get_state_set().contains(Atspi.StateType.SHOWING):
            # Stack pages also carry category names; only activate visible controls.
            if node.get_role() in [Atspi.Role.LABEL,Atspi.Role.PUSH_BUTTON,Atspi.Role.LIST_ITEM,Atspi.Role.PAGE_TAB,Atspi.Role.TEXT,Atspi.Role.ENTRY]:
                return node


def click(app, window, name):
    node = wait(f'control {name}', lambda: find(app,name), app)
    rect = node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('windowactivate','--sync',window)
    xdo('mousemove','--window',window,rect.x+max(5,rect.width//2),rect.y+rect.height//2)
    xdo('click','1')


def edit(app, window, name, value):
    click(app,window,name)
    xdo('key','--clearmodifiers','ctrl+a')
    xdo('type','--clearmodifiers','--delay','5',value)


def text(app,name):
    node = find(app,name)
    return Atspi.Text.get_text(node,0,-1) if node else None


def open_settings(app, main):
    xdo('windowactivate','--sync',main)
    xdo('key','--clearmodifiers','ctrl+comma')
    return wait('settings keyboard shortcut',lambda:xdo('search','--all','--onlyvisible','--pid',app.pid,'--name','^Axo Settings$').splitlines()[0],app)


def window(app):
    return wait('workbench window',lambda:xdo('search','--all','--onlyvisible','--pid',app.pid,'--name','^Axo').splitlines()[0],app)


def assert_inline_field(app, name, caption):
    entry = find(app, name).get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    caption_node = find(app, caption)
    label = caption_node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    assert entry.width >= 32 and entry.x > label.x
    # A single-line GtkLabel can fill a taller row. Check glyph lines, not the
    # allocated widget height, to catch unwanted wrapping without false failures.
    first = Atspi.Text.get_character_extents(caption_node, 0, Atspi.CoordType.WINDOW)
    last = Atspi.Text.get_character_extents(caption_node, len(caption)-1, Atspi.CoordType.WINDOW)
    assert first.y == last.y, 'form caption wrapped despite available horizontal space'
    assert abs((entry.y + entry.height / 2) - (label.y + label.height / 2)) <= 3, 'setting is not an inline form row'


def owned_snapshot(name):
    # Only the private Xvfb fixture; never the person's desktop.
    gi.require_version('Gdk','3.0')
    from gi.repository import Gdk
    Gdk.pixbuf_get_from_window(Gdk.get_default_root_window(),0,0,1440,1000).savev(str(run/name),'png',[],[])


def close_window(window):
    xdo('windowactivate','--sync',window)
    xdo('key','--clearmodifiers','alt+F4')


def stopped(app,name):
    assert app.wait(timeout=7) == 0
    assert 'clean shutdown; terminal widgets released' in (run/f'{name}.log').read_text()


wm=start(['openbox','--sm-disable'],'wm')
ipc=run/'server/axod.sock'
env=dict(os.environ,AXO_PI_EXECUTABLE=str(repo/'crates/axod/testdata/pi-fixture.sh'),AXO_PI_EXTENSION_PATH=str(repo/'crates/axo-server/testdata/pi-extension.js'))
daemon=start([os.environ['AXOD_BINARY'],'--server-dir',str(run/'server'),'--socket',str(ipc),'--host-credentials','files','--relay-url','http://127.0.0.1:9'],'daemon',env=env)
try:
    wait('owned daemon',lambda:ipc.exists() and rpc(ipc,'axo.daemon.health',{})['ready'],daemon)
    rpc(ipc,'axo.config.set',{'key':'shell.command','value':'/bin/sh'})
    session=rpc(ipc,'axo.session.create',{'folder':str(run/'home')})
    keys=['shell.command','agent.command','sessions.idleMinutes','sessions.idleLimit']
    def value(key): return rpc(ipc,'axo.config.get',{'key':key})['value']
    before={key:value(key) for key in keys}
    app=start([str(binary),'--socket',str(ipc)],'settings',cwd=run/'home')
    main=window(app)
    settings=open_settings(app,main)
    wait('loaded shell',lambda:text(app,'Shell command') == '/bin/sh',app)
    assert {key:value(key) for key in keys} == before, 'opening settings wrote configuration'
    assert_inline_field(app, 'Shell command', 'Command')
    shell_bounds = find(app, 'Shell command').get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    assert shell_bounds.y < 120, 'extra header/page hero pushed settings down'
    assert find(app, 'Daemon status') is not None
    owned_snapshot('settings-general.png')
    # Reopening presents the same window and preserves its draft.
    edit(app,settings,'Shell command','/bin/sh -l')
    assert open_settings(app,main) == settings
    assert text(app,'Shell command') == '/bin/sh -l'
    click(app,settings,'Save Shell command')
    wait('shell saved',lambda:value('shell.command') == '/bin/sh -l',app)
    click(app,settings,'Sessions')
    wait('loaded idle value',lambda:text(app,'Idle timeout (minutes)') == before['sessions.idleMinutes'],app)
    assert_inline_field(app, 'Idle timeout (minutes)', 'Put idle Pis to sleep after')
    assert_inline_field(app, 'Maximum idle Pis awake', 'Keep idle Pis awake, at most')
    edit(app,settings,'Idle timeout (minutes)','NaN')
    click(app,settings,'Save Idle timeout (minutes)')
    wait('invalid count reported',lambda:any('Not saved:' in node.get_name() for node in children(app)),app)
    assert value('sessions.idleMinutes') == before['sessions.idleMinutes']
    edit(app,settings,'Idle timeout (minutes)',' 37 ')
    click(app,settings,'Save Idle timeout (minutes)')
    wait('canonical timeout',lambda:value('sessions.idleMinutes') == '37' and text(app,'Idle timeout (minutes)') == '37',app)
    edit(app,settings,'Maximum idle Pis awake','31')
    click(app,settings,'Save Maximum idle Pis awake')
    wait('idle count saved',lambda:value('sessions.idleLimit') == '31',app)
    owned_snapshot('settings-sessions.png')
    click(app,settings,'Agent')
    assert_inline_field(app, 'Agent command', 'Command')
    edit(app,settings,'Agent command','pi --model fixture')
    click(app,settings,'Save Agent command')
    wait('agent command saved',lambda:value('agent.command') == 'pi --model fixture',app)
    edit(app,settings,'Agent command','pi --session /tmp/not-managed-by-ui')
    click(app,settings,'Save Agent command')
    wait('managed agent arguments refused',lambda:any('Not saved:' in node.get_name() for node in children(app)),app)
    assert value('agent.command') == 'pi --model fixture'
    click(app,settings,'Reload values')
    wait('explicit reload discards invalid draft',lambda:text(app,'Agent command') == 'pi --model fixture',app)
    owned_snapshot('settings.png')
    click(app,settings,'Close')  # Actual native CSD button inside the settings sidebar.
    settings=open_settings(app,main)
    wait('settings reopen',lambda:text(app,'Shell command') == '/bin/sh -l',app)
    close_window(main) # Also releases the open settings model/tasks.
    stopped(app,'settings')
    for shell in session['shells']: os.kill(shell['processId'],0)

    # Apply a write but lose its acknowledgement: UI must not claim success or retry.
    fake=run/'lost-ack.sock'
    stored=dict(before)
    writes=[]
    listener=socket.socket(socket.AF_UNIX); listener.bind(str(fake)); listener.listen()
    def serve(connection):
        with connection:
            file=connection.makefile('rb')
            for line in file:
                request=json.loads(line); method=request['method']; params=request['params']
                if method=='axo.protocol.negotiate': result={'protocolVersion':2,'methods':['axo.daemon.health','axo.session.catalog','axo.config.get','axo.config.set']}
                elif method=='axo.daemon.health': result={'version':'fixture','buildNumber':0,'status':'running','ready':True}
                elif method=='axo.session.catalog': result={'sessions':[],'archived':[]}
                elif method=='axo.config.get': result={'key':params['key'],'value':stored[params['key']]}
                elif method=='axo.config.set':
                    stored[params['key']]=params['value']; writes.append(params); return
                else: raise AssertionError(method)
                connection.sendall(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}).encode()+b'\n')
    def accept():
        while True:
            try: connection,_=listener.accept()
            except OSError: return
            threading.Thread(target=serve,args=(connection,),daemon=True).start()
    threading.Thread(target=accept,daemon=True).start()
    app=start([str(binary),'--socket',str(fake)],'uncertain',cwd=run/'home')
    main=window(app); settings=open_settings(app,main)
    wait('fake settings loaded',lambda:text(app,'Shell command') == before['shell.command'],app)
    edit(app,settings,'Shell command','/bin/sh -l')
    click(app,settings,'Save Shell command')
    wait('unknown write outcome',lambda:any('Save could not be confirmed:' in node.get_name() for node in children(app)),app)
    assert len(writes)==1 and not find(app,'Save Shell command').get_state_set().contains(Atspi.StateType.SENSITIVE)
    click(app,settings,'Reload values')
    wait('reconciliation reads actual saved value',lambda:text(app,'Shell command') == '/bin/sh -l' and find(app,'Shell command').get_state_set().contains(Atspi.StateType.SENSITIVE),app)
    assert len(writes)==1
    close_window(main); stopped(app,'uncertain'); listener.close()
    print(json.dumps({'status':'passed','checks':['Mac-referenced grouped inline forms and sidebar-only titlebar','Ctrl+, settings singleton and draft preservation','loads do not write','daemon command/count persistence','server validation and canonical values','no process restart','close with settings open','lost acknowledgement requires reload, no retry']}))
finally:
    for process in reversed(processes):
        if process.poll() is None:
            os.killpg(process.pid,signal.SIGTERM)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL); process.wait()
    for log in logs: log.close()
