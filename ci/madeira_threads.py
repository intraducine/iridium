# SPDX-License-Identifier: AGPL-3.0-only
"""Track guest pthread creation without changing Wine's join/detach ownership."""
from pathlib import Path


def apply(text, source, header):
    calls = {
        'process_ios.c': 'pthread_create( &child_thread, NULL, ios_child_thread_entry, args )',
        'thread_ios.c': 'pthread_create( &pthread_id, &pthread_attr, (void * (*)(void *))start_thread, teb )',
    }
    call = calls[source]
    if text.count(call) != 1:
        raise ValueError('Madeira guest thread creation changed: ' + source)
    return '#include "' + Path(header).as_posix() + '"\n' + text.replace(call, 'ir_windows_' + call)
