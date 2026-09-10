#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Starts one app-lifetime Wine server thread and waits until its master socket,
 * registry, and request loop are initialized. Returns zero on success or a
 * positive errno value on failure.
 */
int iridium_wine_ios_start_embedded_server(
    int debug_enabled,
    char *error_buffer,
    size_t error_buffer_size );

typedef int (*IridiumWineIOSGuestThreadSignal)(uint64_t guest_tid, int signal);

void iridium_wine_ios_register_guest_thread_signal(
    IridiumWineIOSGuestThreadSignal callback );

#ifdef __cplusplus
}
#endif
