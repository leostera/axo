#!/usr/bin/python3
"""Real isolated axod -> shared attach client -> Ghostty GTK; never the paired host."""
import array
import json
import os
import pathlib
import runpy
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time

import gi
gi.require_version('GdkPixbuf', '2.0')
from gi.repository import GdkPixbuf, GLib

if os.environ.get('AXO_DESKTOP_ISOLATED') != '1':
    raise SystemExit('use the isolated desktop launcher')
binary = pathlib.Path(sys.argv[1]).resolve()
run = pathlib.Path(sys.argv[2])
here = pathlib.Path(__file__).resolve().parent
repository = here.parents[2]
rpc = runpy.run_path(str(repository / 'linux/smoke.py'))['rpc']
axod = pathlib.Path(os.environ['AXOD_BINARY']).resolve(strict=True)
ipc = run / 'server/axod.sock'
attach = run / 'server/attach.sock'
state = run / 'fixture.json'
long_line = 'REPLAY_LONG_BEGIN' + '0123456789' * 16 + 'REPLAY_LONG_END'
processes = []
logs = []


def wait_for(description, check, process, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'{description}: process exited {process.returncode}; artifacts {run}')
        try:
            value = check()
            if value:
                return value
        except (OSError, ValueError, KeyError, IndexError, GLib.Error, subprocess.CalledProcessError):
            pass
        time.sleep(0.05)
    raise RuntimeError(f'timed out: {description}; artifacts {run}')


def read(path):
    return json.loads(path.read_text())


def start(command, name, **options):
    log = (run / f'{name}.log').open('w')
    logs.append(log)
    process = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True, **options)
    processes.append(process)
    return process


def xdo(*arguments):
    return subprocess.check_output(['xdotool', *map(str, arguments)], text=True, stderr=subprocess.PIPE).strip()


def window_for(app):
    window = wait_for('GTK window', lambda: xdo('search', '--onlyvisible', '--pid', app.pid, '--name', 'AxoDesktop').splitlines()[0], app)
    wait_for('window activation', lambda: xdo('windowactivate', '--sync', window) or True, app)
    return window


def launch(name, socket_path=attach, shell=None):
    diagnostics = run / f'{name}.json'
    picture = run / f'{name}.png'
    app = start([str(binary), '--attach-socket', str(socket_path), '--shell', str(shell),
                 '--diagnostics', str(diagnostics), '--snapshot', str(picture)], name, cwd=run / 'home')
    return app, diagnostics, picture


def stop_view(app, window, name):
    xdo('windowactivate', '--sync', window)
    xdo('key', '--clearmodifiers', 'alt+F4')
    assert app.wait(timeout=5) == 0, f'{name}: unclean frontend exit'
    content = (run / f'{name}.log').read_text()
    assert 'clean shutdown; terminal widgets released' in content
    assert 'started subcommand' not in content, 'attached frontend spawned a fallback shell'


def rendered_text(app, window):
    xdo('windowactivate', '--sync', window)
    xdo('key', '--clearmodifiers', 'ctrl+shift+a')
    xdo('key', '--clearmodifiers', 'ctrl+shift+c')
    def copied():
        result = subprocess.check_output(['/usr/bin/python3', str(here / 'clipboard_text.py')], text=True, timeout=5)
        return json.loads(result)['text']
    return wait_for('copied rendered terminal text', copied, app)


def green_pixels(path):
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(path))
    pixels = pixbuf.get_pixels()
    channels, stride = pixbuf.get_n_channels(), pixbuf.get_rowstride()
    return sum(1 for y in range(pixbuf.get_height()) for x in range(pixbuf.get_width())
               if all(abs(a-b) < 20 for a,b in zip(pixels[y*stride+x*channels:y*stride+x*channels+3], (64,224,128))))


wm = start(['openbox', '--sm-disable'], 'wm')
environment = dict(os.environ, AXO_PI_EXECUTABLE=str(repository / 'crates/axod/testdata/pi-fixture.sh'),
                   AXO_PI_EXTENSION_PATH=str(repository / 'crates/axo-server/testdata/pi-extension.js'))
daemon = start([str(axod), '--server-dir', str(run / 'server'), '--socket', str(ipc),
                '--host-credentials', 'files', '--relay-url', 'http://127.0.0.1:9'], 'daemon', env=environment)
try:
    wait_for('isolated daemon ready', lambda: ipc.exists() and rpc(ipc, 'axo.daemon.health', {})['ready'], daemon)
    rpc(ipc, 'axo.config.set', {'key':'shell.command','value':'/bin/sh'})
    session = rpc(ipc, 'axo.session.create', {'folder':str(run / 'home')})
    terminal = next(shell for shell in session['shells'] if shell['role'] == 'terminal')
    ids = {'sessionId':session['id'],'shellId':terminal['id']}
    rpc(ipc, 'axo.terminal.resize', dict(ids, rows=45, columns=200))
    command = shlex.join(['/usr/bin/python3','-u',str(here / 'terminal_fixture.py'),str(state),'--replay-probe'])
    rpc(ipc, 'axo.terminal.write', dict(ids, text=command+'\r'))
    original = wait_for('fixture before any frontend', lambda: read(state), daemon)
    assert (original['rows'],original['columns']) == (45,200)
    wait_for('daemon captured output without a frontend', lambda: 'REPLAY_LONG_END' in rpc(ipc,'axo.terminal.screen',ids)['text'], daemon)

    # Shipped Mac/peer clients still use v2: its next byte after the length is
    # the descriptor marker, never v3 grid metadata.
    with socket.socket(socket.AF_UNIX) as legacy:
        legacy.settimeout(5)
        legacy.connect(str(attach))
        legacy.sendall(f"{terminal['id']}\n".encode())
        header = b''
        while len(header) < 8:
            part = legacy.recv(8-len(header))
            assert part
            header += part
        assert int.from_bytes(header,'big') < 8*1024*1024
        marker, control, flags, _ = legacy.recvmsg(1, socket.CMSG_SPACE(512*4), socket.MSG_CMSG_CLOEXEC)
        descriptors = []
        for level, kind, value in control:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                numbers = array.array('i')
                numbers.frombytes(value)
                descriptors.extend(numbers)
        try:
            assert marker == b'1' and not flags & socket.MSG_CTRUNC and len(descriptors) == 1
        finally:
            for descriptor in descriptors:
                os.close(descriptor)

    app, diagnostics, picture = launch('first', shell=terminal['id'])
    first = wait_for('daemon-backed surface', lambda: (r if (r := read(diagnostics))['ready'] else None), app)
    window = window_for(app)
    wait_for('original replay actually rendered', lambda: picture.exists() and green_pixels(picture) > 200, app)
    copied = rendered_text(app, window)
    assert long_line in copied.replace('\n','').replace('\r',''), 'initial replay parsed at the wrong grid'
    assert 'GHOSTTY_RENDER_PROBE' in copied
    xdo('type','--clearmodifiers','--delay','25','through-gtk')
    xdo('key','--clearmodifiers','Return')
    wait_for('input reached daemon-owned child', lambda: read(state)['input'] == 'through-gtk', app)
    xdo('windowsize','--sync',window,'1180','780')
    resized = wait_for('native grid resized', lambda: (r if (r := read(diagnostics))['columns'] > first['columns'] else None), app)
    wait_for('PTY got matching SIGWINCH', lambda: read(state)['columns'] == resized['columns'] and read(state)['rows'] == resized['rows'], app)
    stop_view(app, window, 'first')
    assert read(state)['pid'] == original['pid'] and not read(state)['exited']
    os.kill(original['pid'], 0)
    rpc(ipc,'axo.terminal.write',dict(ids,text='while-detached\r'))
    wait_for('child and output pump survived frontend close', lambda: read(state)['input'] == 'while-detached' and 'INPUT_OK: while-detached' in rpc(ipc,'axo.terminal.screen',ids)['text'], daemon)

    app, diagnostics, picture = launch('second', shell=terminal['id'])
    wait_for('reattached surface', lambda: read(diagnostics)['ready'], app)
    window = window_for(app)
    wait_for('reattached replay visibly rendered', lambda: picture.exists() and green_pixels(picture) > 200, app)
    copied = rendered_text(app, window)
    assert 'INPUT_OK: while-detached' in copied
    assert long_line in copied.replace('\n','').replace('\r','')
    stop_view(app, window, 'second')
    assert read(state)['pid'] == original['pid'] and daemon.poll() is None

    app, _, _ = launch('refused', shell=9223372036854775807)
    window = window_for(app)
    wait_for('explicit attachment refusal', lambda: 'attachment failed:' in (run/'refused.log').read_text(), app)
    stop_view(app, window, 'refused')

    # A view closed during a stalled handshake must release its UI callback/engine.
    stalled_path = run / 'stalled.sock'
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(stalled_path))
        listener.listen(1)
        peer_closed = threading.Event()
        def stall():
            with listener.accept()[0] as connection:
                connection.settimeout(5)
                connection.recv(64)
                while connection.recv(64):
                    pass
                peer_closed.set()
        thread = threading.Thread(target=stall, daemon=True)
        thread.start()
        app, _, _ = launch('cancelled', socket_path=stalled_path, shell=terminal['id'])
        window = window_for(app)
        stop_view(app, window, 'cancelled')
        assert peer_closed.wait(5), 'cancelled client retained the attachment connection'
        thread.join(timeout=1)
    assert read(state)['pid'] == original['pid'] and not read(state)['exited']
    print(json.dumps({'status':'passed','checks':['isolated real axod','legacy v2 unchanged','v3 rendered replay at captured grid','live PTY keyboard input','resize/SIGWINCH','close is detach, child survives','output pump while detached','frontend restart/replay','refusal without fallback','pending attach cancellation'], 'originalGrid':[200,45], 'resizedGrid':[resized['columns'],resized['rows']]}))
finally:
    # Only owned test processes; retained private artifacts, no data removal.
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
