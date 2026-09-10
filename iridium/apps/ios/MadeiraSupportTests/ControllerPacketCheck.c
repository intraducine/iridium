#include "../MadeiraSupport/controller_packet.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    uint8_t data[68] = {0}, pad[12] = {0}; uint32_t sequence = 0;
    assert(!controller_packet(data, 68, 0, &sequence, pad));
    data[0] = 9; data[52] = 1;
    data[56] = 1; data[57] = 0x80; /* fourth controller: D-pad up + Y */
    data[58] = 127; data[59] = 255; /* analog triggers */
    data[60] = 0; data[61] = 0x80; /* full negative left X */
    assert(controller_packet(data, 68, 3, &sequence, pad));
    assert(sequence == 9 && pad[0] == 1 && pad[1] == 0x80);
    assert(pad[2] == 127 && pad[3] == 255 && pad[5] == 0x80);
    assert(!controller_packet(data, 67, 3, &sequence, pad));
    assert(!controller_packet(data, 68, 4, &sequence, pad));
    puts("PASS: XInput packet, fourth player, analog values, disconnect, truncation");
}
