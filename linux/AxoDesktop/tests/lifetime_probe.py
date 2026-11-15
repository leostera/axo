#!/usr/bin/python3
"""Separate process: the private native ABI must reject an unrealized live widget."""
import ctypes
import os
import socket
import sys
import termios

native = ctypes.CDLL(sys.argv[1])
native.axo_gtk_engine_new.argtypes = []
native.axo_gtk_engine_new.restype = ctypes.c_void_p
native.axo_gtk_surface_new.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
native.axo_gtk_surface_new.restype = ctypes.c_void_p
native.axo_gtk_engine_free.argtypes = [ctypes.c_void_p]
native.axo_gtk_engine_free.restype = ctypes.c_int
gobject = ctypes.CDLL('libgobject-2.0.so.0')
gobject.g_object_ref_sink.argtypes = [ctypes.c_void_p]
gobject.g_object_ref_sink.restype = ctypes.c_void_p
gobject.g_object_unref.argtypes = [ctypes.c_void_p]

engine = native.axo_gtk_engine_new()
assert engine, 'engine initialization failed'
widget = native.axo_gtk_surface_new(engine, None)
assert widget, 'unrealized widget creation failed'
gobject.g_object_ref_sink(widget)
if native.axo_gtk_engine_free(engine) != -1:
    # Do not dereference a widget after a broken bridge has freed its allocator.
    sys.exit('bridge incorrectly freed an engine with a live unrealized widget')
gobject.g_object_unref(widget)
class ExternalTerminal(ctypes.Structure):
    _fields_ = [('output_fd', ctypes.c_int), ('pty_fd', ctypes.c_int),
                ('columns', ctypes.c_uint16), ('rows', ctypes.c_uint16),
                ('replay', ctypes.c_void_p), ('replay_len', ctypes.c_size_t)]

assert ctypes.sizeof(ExternalTerminal) == 32
native.axo_gtk_surface_attach.argtypes = [ctypes.c_void_p, ctypes.POINTER(ExternalTerminal)]
native.axo_gtk_surface_attach.restype = ctypes.c_void_p
master, slave = os.openpty()
termios.tcsetwinsize(master, (25, 80))
output, peer = socket.socketpair()
replay = ctypes.create_string_buffer(b'')
external = ExternalTerminal(output.fileno(), master, 80, 25, ctypes.addressof(replay), 0)
widget = native.axo_gtk_surface_attach(engine, ctypes.byref(external))
assert widget
assert native.axo_gtk_engine_free(engine) == -1, 'unrealized external widget lost its engine'
gobject.g_object_ref_sink(widget)
gobject.g_object_unref(widget)
os.fstat(master)
os.fstat(output.fileno())  # Borrowed originals are still the host's to close.
os.close(master)
os.close(slave)
output.close()
peer.close()
assert native.axo_gtk_engine_free(engine) == 0, 'engine did not release after widget destruction'
print('standalone/external unrealized widget teardown guards: passed')
