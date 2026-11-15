#!/usr/bin/python3
"""Real Ghostty metrics -> owned daemon -> hidden/new pane grids, including transport uncertainty."""
import os
import pathlib
import runpy

if os.environ.get('AXO_DESKTOP_ISOLATED') != '1':
    raise SystemExit('use the isolated desktop launcher')
os.environ['AXO_DESKTOP_RECONNECT_TEST'] = '1'
os.environ['AXO_DESKTOP_VIEWPORT_TEST'] = '1'
runpy.run_path(str(pathlib.Path(__file__).with_name('workbench_drive.py')), run_name='__main__')
