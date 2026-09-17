#!/usr/bin/env python3
"""Verify the diagnostic native snapshot and current app-facing bridges."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
M = 'testrepos/Madeira/'
# Native objects from 65b596; app-facing bridge objects from e62b22f5.
# Object identities work in shallow Actions checkouts without fetching history.
EXPECTED = {
    M + 'FEX': 'afb45b820b684e065fee9562200b7f5a52ffce6b',
    M + 'wine': '9ea18dba3562d32fb4a551a2b0e3fdfefa054a82',
    M + 'build': '558ef5859ff072fe6bd8b77d005f4e9235a09e20',
    M + 'app/Madeira/Winios/Winios.m': '69b6910640087a2cecb813d2c718ee3e68e039cf',
    M + 'app/Madeira/StikJITHelper.swift': '58d6058aa1cd9f24308e515fdea067169f9916f1',
    M + 'app/Madeira/WineProcessBridge.h': '84929f1daaf04dbadfa1a7be864673c10247e7bd',
    M + 'app/Madeira/WineProcessBridge.m': 'ad808651875e8d29f907bbe68b79ae780d71c981',
    M + 'app/Madeira/WineServerBridge.m': '9d616b0910cc4b58884d3c97a845bb44fff934e5',
}


def check(root=ROOT, expected=None):
    expected = EXPECTED if expected is None else expected
    for path, identity in expected.items():
        actual = subprocess.check_output(
            ['git', '-C', str(root), 'rev-parse', 'HEAD:' + path], text=True
        ).strip()
        if actual != identity:
            raise ValueError('Hybrid source mismatch: ' + path)
    # Compiler outputs are untracked; tracked/submodule source modifications
    # are not part of the historical experiment and must not slip through.
    changed = subprocess.check_output(
        ['git', '-C', str(root), 'diff', '--name-only', '--ignore-submodules=none',
         'HEAD', '--', *expected], text=True
    ).strip()
    if changed:
        raise ValueError('Hybrid sources have local changes: ' + changed)
    print('Verified hybrid: 65b596 native sources; e62 app-facing JIT/process bridges')


if __name__ == '__main__':
    check()
