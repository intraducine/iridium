# SPDX-License-Identifier: AGPL-3.0-only
"""Give Wine's final PCM mix the same app-owned game gain as console engines."""


def apply(text):
    start = 'static OSStatus ios_audio_render_cb('
    finish = '    atomic_fetch_add_explicit(&g_dev.cb_epoch, 1, memory_order_release);'
    if text.count(start) != 1 or text.count(finish) != 1:
        raise ValueError('Madeira final audio callback changed')
    return text.replace(start, 'extern void ir_audio_volume_apply_float(float *, size_t);\n\n' + start).replace(
        finish, '    ir_audio_volume_apply_float(out, total);\n' + finish)
