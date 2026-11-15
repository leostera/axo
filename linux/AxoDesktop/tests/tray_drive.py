#!/usr/bin/python3
"""Real frontend + daemon, simulated SNI watcher/host on a private session bus."""
import json
import os
import pathlib
import runpy
import signal
import subprocess
import sys
import time
import gi
gi.require_version('Gio','2.0')
gi.require_version('Atspi','2.0')
from gi.repository import Gio, GLib, Atspi

if os.environ.get('AXO_DESKTOP_ISOLATED') != '1': raise SystemExit('use private desktop launcher')
binary,run=pathlib.Path(sys.argv[1]).resolve(),pathlib.Path(sys.argv[2])
repo=pathlib.Path(__file__).resolve().parents[3]
rpc=runpy.run_path(str(repo/'linux/smoke.py'))['rpc']
processes,logs=[],[]
context=GLib.MainContext.default()


def start(command,name,**options):
    log=(run/f'{name}.log').open('w'); logs.append(log)
    process=subprocess.Popen(command,stdout=log,stderr=log,start_new_session=True,**options)
    processes.append(process); return process


def wait(description,check,process,timeout=20):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        while context.pending(): context.iteration(False)
        if process.poll() is not None: raise RuntimeError(f'{description}: exited {process.returncode}; {run}')
        try:
            value=check()
            if value: return value
        except (OSError,ValueError,KeyError,IndexError,GLib.Error,subprocess.CalledProcessError): pass
        time.sleep(.04)
    raise RuntimeError(f'timed out: {description}; {run}')


def xdo(*args):
    return subprocess.check_output(['xdotool',*map(str,args)],text=True,stderr=subprocess.PIPE).strip()


def visible(app):
    result=subprocess.run(['xdotool','search','--all','--onlyvisible','--pid',str(app.pid),'--name','^Axo($| ·)'],capture_output=True,text=True)
    return result.stdout.strip() if result.returncode==0 else None


def close(window):
    xdo('windowactivate','--sync',window); xdo('key','--clearmodifiers','alt+F4')


def native_close(app,window):
    def control():
        desktop=Atspi.get_desktop(0)
        pending=[desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
        pending=[node for node in pending if node.get_process_id()==app.pid]
        while pending:
            node=pending.pop()
            if node.get_role()==Atspi.Role.PUSH_BUTTON and node.get_name()=='Close' and node.get_state_set().contains(Atspi.StateType.SHOWING):
                return node
            pending.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))
    button=wait('native window close control',control,app)
    bounds=button.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('windowactivate','--sync',window)
    xdo('mousemove','--window',window,bounds.x+bounds.width//2,bounds.y+bounds.height//2)
    xdo('click','1')


def stopped(app,name):
    assert app.wait(timeout=7)==0
    log=(run/f'{name}.log').read_text()
    assert 'clean shutdown; terminal widgets released' in log
    assert 'error getting termios mode' not in log


bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
watcher='org.kde.StatusNotifierWatcher'
registered=[]; host=[False]
xml='''<node><interface name="org.kde.StatusNotifierWatcher">
<method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
<property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
<property name="ProtocolVersion" type="i" access="read"/>
<property name="RegisteredStatusNotifierItems" type="as" access="read"/>
</interface></node>'''
def method(connection,sender,path,interface,name,parameters,invocation):
    assert name=='RegisterStatusNotifierItem' and parameters.unpack()[0]==sender
    registered.append(sender); invocation.return_value(GLib.Variant('()',()))
def prop(connection,sender,path,interface,name):
    if name=='IsStatusNotifierHostRegistered': return GLib.Variant('b',host[0])
    if name=='ProtocolVersion': return GLib.Variant('i',0)
    if name=='RegisteredStatusNotifierItems': return GLib.Variant('as',registered)
    raise AssertionError(name)
node=Gio.DBusNodeInfo.new_for_xml(xml)
registration=bus.register_object('/StatusNotifierWatcher',node.interfaces[0],method,prop,None)
owner=Gio.bus_own_name_on_connection(bus,watcher,Gio.BusNameOwnerFlags.NONE,None,None)


def call(service,path,interface,method,signature=None,args=None):
    parameters=GLib.Variant(signature,args) if signature else None
    return bus.call_sync(service,path,interface,method,parameters,None,Gio.DBusCallFlags.NONE,3000,None).unpack()


def event(service,id):
    return call(service,'/MenuBar','com.canonical.dbusmenu','Event','(isvu)',(id,'clicked',GLib.Variant('i',0),0))


def launch(name):
    previous=len(registered)
    app=start([str(binary),'--socket',str(ipc)],name,cwd=run/'home')
    main=wait('native workbench',lambda:visible(app),app)
    service=wait('SNI registration',lambda:registered[-1] if len(registered)>previous else None,app)
    assert call('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','GetConnectionUnixProcessID','(s)',(service,))[0]==app.pid
    return app,main,service


wm=start(['openbox','--sm-disable'],'wm')
ipc=run/'server/axod.sock'
env=dict(os.environ,AXO_PI_EXECUTABLE=str(repo/'crates/axod/testdata/pi-fixture.sh'),AXO_PI_EXTENSION_PATH=str(repo/'crates/axo-server/testdata/pi-extension.js'))
daemon=start([os.environ['AXOD_BINARY'],'--server-dir',str(run/'server'),'--socket',str(ipc),'--host-credentials','files','--relay-url','http://127.0.0.1:9'],'daemon',env=env)
try:
    wait('owned daemon',lambda:ipc.exists() and rpc(ipc,'axo.daemon.health',{})['ready'],daemon)
    rpc(ipc,'axo.config.set',{'key':'shell.command','value':'/bin/sh'})
    session=rpc(ipc,'axo.session.create',{'folder':str(run/'home')})
    app,main,service=launch('no-host')
    native_close(app,main); stopped(app,'no-host') # Watcher alone is not a recovery affordance.

    host[0]=True
    app,main,service=launch('tray')
    def daemon_status():
        revision,layout=call(service,'/MenuBar','com.canonical.dbusmenu','GetLayout','(iias)',(0,-1,[]))
        assert len(layout[2])==5
        return next(child[1]['label'] for child in layout[2] if child[0]==5).startswith('Daemon running')
    wait('tray daemon status',daemon_status,app)
    assert call(service,'/StatusNotifierItem','org.freedesktop.DBus.Properties','Get','(ss)',('org.kde.StatusNotifierItem','Menu'))[0]=='/MenuBar'
    grouped=call(service,'/MenuBar','com.canonical.dbusmenu','GetGroupProperties','(aias)',([1,2],['label']))[0]
    assert [row[0] for row in grouped]==[1,2] and all(set(row[1])=={'label'} for row in grouped)
    assert call(service,'/MenuBar','com.canonical.dbusmenu','GetProperty','(is)',(1,'label'))[0]=='Show Axo'
    assert call(service,'/MenuBar','com.canonical.dbusmenu','AboutToShow','(i)',(0,))==(False,)
    assert call(service,'/MenuBar','com.canonical.dbusmenu','EventGroup','(a(isvu))',([(999,'clicked',GLib.Variant('i',0),0)],))[0]==[999]
    for path,interface,method,signature,args in [
        ('/StatusNotifierItem','org.freedesktop.DBus.Properties','Get','(ss)',('org.kde.StatusNotifierItem','not-a-property')),
        ('/MenuBar','com.canonical.dbusmenu','GetLayout','(iias)',(0,-2,[])),
    ]:
        try: call(service,path,interface,method,signature,args)
        except GLib.Error: pass
        else: raise AssertionError('invalid protocol request accepted')
    # Unknown menu IDs fail, and cannot accidentally become Quit.
    try: event(service,999)
    except GLib.Error: pass
    else: raise AssertionError('unknown menu action accepted')
    native_close(app,main)
    wait('window close hides with a registered host',lambda:not visible(app),app)
    terminal=next(shell for shell in session['shells'] if shell['role']=='terminal')
    ids={'sessionId':session['id'],'shellId':terminal['id']}
    rpc(ipc,'axo.terminal.write',dict(ids,text="printf 'TRAY_%s_OUTPUT\\n' HIDDEN\r"))
    wait('daemon output while hidden',lambda:'TRAY_HIDDEN_OUTPUT' in rpc(ipc,'axo.terminal.screen',ids)['text'],app)
    call(service,'/StatusNotifierItem','org.kde.StatusNotifierItem','Activate','(ii)',(0,0))
    main=wait('tray activation restores window',lambda:visible(app),app)
    xdo('windowactivate','--sync',main)
    xdo('mousemove','--window',main,'1000','200'); xdo('click','1')
    xdo('key','--clearmodifiers','ctrl+shift+a'); xdo('key','--clearmodifiers','ctrl+shift+c')
    def rendered():
        data=subprocess.check_output(['/usr/bin/python3',str(pathlib.Path(__file__).parent/'clipboard_text.py')],text=True,timeout=5)
        return 'TRAY_HIDDEN_OUTPUT' in json.loads(data)['text']
    wait('hidden output rendered by the restored native surface',rendered,app)
    event(service,3)
    settings=wait('tray opens settings',lambda:xdo('search','--all','--onlyvisible','--pid',app.pid,'--name','^Axo Settings$'),app)
    close(settings)
    event(service,2); wait('menu hides window',lambda:not visible(app),app)
    host[0]=False
    main=wait('host disappears while watcher stays: restore window',lambda:visible(app),app,timeout=8)
    host[0]=True
    def hidden_again(): event(service,2); return not visible(app)
    wait('host returns: hide works again',hidden_again,app,timeout=8)
    Gio.bus_unown_name(owner); owner=None
    main=wait('watcher loss restores window',lambda:visible(app),app,timeout=8)
    close(main); stopped(app,'tray')

    owner=Gio.bus_own_name_on_connection(bus,watcher,Gio.BusNameOwnerFlags.NONE,None,None)
    app,main,service=launch('quit')
    wait('host re-registration health',daemon_status,app)
    event(service,4); stopped(app,'quit')
    for shell in session['shells']: os.kill(shell['processId'],0)
    assert daemon.poll() is None
    print(json.dumps({'status':'passed','checks':['native SNI and DBusMenu export','watcher without host does not hide','daemon status','native window close and show/hide/settings/quit','hidden output survives and renders on restore','invalid menu ID refusal','host loss restores hidden window even with live watcher','watcher loss and re-registration','quit is detach, daemon children survive']}))
finally:
    if owner is not None: Gio.bus_unown_name(owner)
    bus.unregister_object(registration)
    for process in reversed(processes):
        if process.poll() is None:
            os.killpg(process.pid,signal.SIGTERM)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL); process.wait()
    for log in logs: log.close()
