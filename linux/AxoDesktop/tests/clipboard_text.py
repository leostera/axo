#!/usr/bin/python3
"""Read only the isolated X server's clipboard after an explicit test copy action."""
import json
import os
import gi

if os.environ.get('AXO_DESKTOP_ISOLATED') != '1':
    raise SystemExit('clipboard probe requires the isolated desktop launcher')

gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, Gdk, GLib
Gtk.init()
loop = GLib.MainLoop()
result = {'text': None}


def ready(clipboard, response):
    try:
        result['text'] = clipboard.read_text_finish(response)
    finally:
        loop.quit()


Gdk.Display.get_default().get_clipboard().read_text_async(None, ready)
GLib.timeout_add(3000, lambda: (loop.quit(), False)[1])
loop.run()
print(json.dumps(result))
