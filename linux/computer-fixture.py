#!/usr/bin/env python3
"""Harmless GTK window for the isolated Linux desktop acceptance test."""
import gi

gi.require_version('Gtk', '4.0')
from gi.repository import Gtk


class Fixture(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='dev.leostera.axo.linuxfixture')

    def do_activate(self):
        window = Gtk.ApplicationWindow(application=self, title='Axo Linux test fixture')
        window.set_default_size(480, 240)
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        layout.set_margin_top(24)
        layout.set_margin_bottom(24)
        layout.set_margin_start(24)
        layout.set_margin_end(24)
        entry = Gtk.Entry()
        entry.update_property([Gtk.AccessibleProperty.LABEL], ['Axo fixture input'])
        button = Gtk.Button(label='Copy input')
        result = Gtk.Label(label='Echo: empty')
        button.connect('clicked', lambda _: result.set_label('Echo: ' + entry.get_text()))
        for widget in [entry, button, result]:
            layout.append(widget)
        window.set_child(layout)
        window.present()


Fixture().run([])
