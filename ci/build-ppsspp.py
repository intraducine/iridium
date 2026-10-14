#!/usr/bin/env python3
"""Compatibility entry point for the complete native iOS PPSSPP builder."""
from pathlib import Path
import runpy

if __name__ == '__main__':
    runpy.run_path(str(Path(__file__).with_name('build-ppsspp-native.py')), run_name='__main__')
