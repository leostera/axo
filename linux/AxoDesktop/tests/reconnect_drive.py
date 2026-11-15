#!/usr/bin/python3
"""Workbench acceptance plus isolated RPC/attachment cuts against an unchanged owned daemon."""
import os
import pathlib
import runpy

if os.environ.get('AXO_DESKTOP_ISOLATED') != '1':
    raise SystemExit('use the isolated desktop launcher')
os.environ['AXO_DESKTOP_RECONNECT_TEST'] = '1'
runpy.run_path(str(pathlib.Path(__file__).with_name('workbench_drive.py')), run_name='__main__')
