#include <stdint.h>
#include <stddef.h>
#include <string.h>
static int controller_packet(const uint8_t *bytes, size_t size, unsigned index,
                             uint32_t *sequence, void *gamepad) {
    if (size != 68 || index >= 4 || !bytes[4 + index * 16]) return 0;
    memcpy(sequence, bytes, 4);
    memcpy(gamepad, bytes + 8 + index * 16, 12);
    return 1;
}
