#!/usr/bin/env python3
"""Owned GUI fixture: synthetic values are verified by digest, never echoed."""
import hashlib
import os
from pathlib import Path
import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk


class Fixture(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="dev.leostera.axo.secureinputfixture")

    def do_activate(self):
        window = Gtk.ApplicationWindow(application=self, title="Axo secure input fixture")
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        window.set_default_size(480, 260)
        email = Gtk.Entry()
        email.update_property([Gtk.AccessibleProperty.LABEL], ["Email"])
        password = Gtk.PasswordEntry()
        password.update_property([Gtk.AccessibleProperty.LABEL], ["Password"])
        submit = Gtk.Button(label="Verify input")
        replace = Gtk.Button(label="Replace password")
        report = Path(os.environ["XDG_RUNTIME_DIR"]) / "gui-input-digest"
        submit.connect("clicked", lambda _: report.write_text(hashlib.sha256(
            (email.get_text() + "\n" + password.get_text()).encode()).hexdigest()))

        def replace_password(_):
            nonlocal password
            layout.remove(password)
            password = Gtk.PasswordEntry()
            password.update_property([Gtk.AccessibleProperty.LABEL], ["Password"])
            layout.insert_child_after(password, email)
            (report.parent / "gui-input-replaced").write_text("replaced")

        replace.connect("clicked", replace_password)
        for widget in [email, password, submit, replace]:
            layout.append(widget)
        window.set_child(layout)
        window.present()


Fixture().run([])
