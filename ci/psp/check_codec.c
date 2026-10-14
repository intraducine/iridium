// SPDX-License-Identifier: AGPL-3.0-only
#include <stdbool.h>
#include <stdio.h>
bool ir_native_psp_codec_check(void);
int main(void) {
    if (!ir_native_psp_codec_check()) {
        fputs("Linked H.264 decode or AAC availability failed\n", stderr);
        return 1;
    }
    puts("Linked H.264 frame decoded: 16x16 red; AAC decoder available");
    return 0;
}
