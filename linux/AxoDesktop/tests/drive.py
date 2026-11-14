#!/usr/bin/python3
"""Exercise only the prototype's own isolated X11 window and PTY fixture."""
import ctypes
import json
import os
import pathlib
import shlex
import signal
import subprocess
import sys
import time

import gi
gi.require_version('GdkPixbuf', '2.0')
from gi.repository import GdkPixbuf, GLib

binary = pathlib.Path(sys.argv[1]).resolve()
run = pathlib.Path(sys.argv[2])
fixture = pathlib.Path(__file__).with_name('terminal_fixture.py').resolve()
state = run / 'pty.json'
diagnostics = run / 'surface.json'
picture = run / 'window.png'


def wait_for(description, observe, process, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'prototype exited before {description}; inspect {run / "app.log"}')
        try:
            result = observe()
            if result:
                return result
        except (OSError, ValueError, KeyError, IndexError, GLib.Error, subprocess.CalledProcessError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f'timed out waiting for {description}; inspect {run}')


def read(path):
    return json.loads(path.read_text())


def xdo(*arguments):
    return subprocess.check_output(['xdotool', *map(str, arguments)], text=True, stderr=subprocess.PIPE).strip()


def green_pixels():
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(picture))
    pixels = pixbuf.get_pixels()
    channels = pixbuf.get_n_channels()
    stride = pixbuf.get_rowstride()
    count = 0
    for y in range(pixbuf.get_height()):
        for x in range(pixbuf.get_width()):
            at = y * stride + x * channels
            r, g, b = pixels[at:at + 3]
            if abs(r - 64) < 20 and abs(g - 224) < 20 and abs(b - 128) < 20:
                count += 1
    return count


log = (run / 'app.log').open('w')
native_library = pathlib.Path(os.environ['GHOSTTY_RESOURCES_DIR']).parent.parent / 'lib/libaxo-ghostty-gtk.so'
subprocess.run(['/usr/bin/python3', str(fixture.with_name('lifetime_probe.py')), str(native_library)],
               check=True, timeout=20, stdout=log, stderr=log)
# Empty config must stay untouched; an existing canary must not even be opened.
configuration = run / 'config/ghostty/config.ghostty'
assert not configuration.parent.exists(), 'native probe created Ghostty configuration'
configuration.parent.mkdir()
canary = '# Owned config-access canary; never an actual user file.\nfont-size = 48\n'
configuration.write_text(canary)
libc = ctypes.CDLL(None, use_errno=True)
libc.inotify_init1.argtypes = [ctypes.c_int]
libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
watch_fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
assert watch_fd >= 0
assert libc.inotify_add_watch(watch_fd, os.fsencode(configuration), 0x21) >= 0  # IN_OPEN | IN_ACCESS
wm_log = (run / 'wm.log').open('w')
wm = subprocess.Popen(['openbox', '--sm-disable'], stdout=wm_log, stderr=wm_log)
command = shlex.join(['/usr/bin/python3', '-u', str(fixture), str(state)])
app = subprocess.Popen([str(binary), '--command', command, '--snapshot', str(picture), '--diagnostics', str(diagnostics)],
                       cwd=run / 'home', stdout=log, stderr=log, start_new_session=True)
try:
    initial = wait_for('real Ghostty surface', lambda: (r if (r := read(diagnostics)).get('ready') else None), app)
    child = wait_for('PTY fixture', lambda: read(state), app)
    assert child['tty'] and child['columns'] > 0 and child['rows'] > 0
    window = wait_for('prototype window', lambda: xdo('search', '--onlyvisible', '--pid', app.pid, '--name', 'AxoDesktop').splitlines()[0], app)
    wait_for('window manager activation', lambda: xdo('windowactivate', '--sync', window) or True, app)
    xdo('type', '--clearmodifiers', '--delay', '35', 'axo-rust-gtk-input')
    xdo('key', '--clearmodifiers', 'Return')
    wait_for('keyboard input through Ghostty PTY', lambda: read(state)['input'] == 'axo-rust-gtk-input', app)
    xdo('windowsize', '--sync', window, '1180', '780')
    resized = wait_for('native grid resize', lambda: (r if (r := read(diagnostics))['columns'] > initial['columns'] and r['rows'] > initial['rows'] else None), app)
    wait_for('SIGWINCH to child', lambda: read(state)['columns'] == resized['columns'] and read(state)['rows'] == resized['rows'], app)
    wait_for('rendered terminal pixels', lambda: picture.exists() and green_pixels() > 200, app)
    colors = green_pixels()
    xdo('type', '--clearmodifiers', '--delay', '35', 'quit')
    xdo('key', '--clearmodifiers', 'Return')
    wait_for('child exit', lambda: read(state)['exited'], app)
    time.sleep(0.3)
    xdo('key', '--clearmodifiers', 'alt+F4')
    result = app.wait(timeout=10)
    assert result == 0, f'prototype did not shut down cleanly: {result}'
    log.flush()
    assert 'clean shutdown; terminal widgets released' in (run / 'app.log').read_text()
    try:
        accesses = os.read(watch_fd, 4096)
    except BlockingIOError:
        accesses = b''
    assert not accesses, 'prototype opened/read the existing Ghostty config canary'
    os.close(watch_fd)
    watch_fd = -1
    assert configuration.read_text() == canary, 'prototype modified Ghostty configuration'
    print(json.dumps({'status':'passed','checks':['unrealized widget lifetime guard','no Ghostty config access','Rust GTK4 window','real Ghostty widget and rendered pixels','PTY keyboard input','resize and SIGWINCH','child exit','clean widget/engine teardown'],
                      'initialGrid':[initial['columns'],initial['rows']], 'resizedGrid':[resized['columns'],resized['rows']], 'greenTerminalPixels':colors,'snapshot':str(picture)}))
finally:
    if watch_fd >= 0:
        os.close(watch_fd)
    if app.poll() is None:
        os.killpg(app.pid, signal.SIGTERM)
        try:
            app.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(app.pid, signal.SIGKILL)
            app.wait()
    wm.terminate()
    wm.wait(timeout=5)
    log.close()
    wm_log.close()
