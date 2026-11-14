#!/usr/bin/python3
"""Separate process: the private native ABI must reject an unrealized live widget."""
import ctypes
import sys

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
assert native.axo_gtk_engine_free(engine) == 0, 'engine did not release after widget destruction'
print('unrealized widget teardown guard: passed')
