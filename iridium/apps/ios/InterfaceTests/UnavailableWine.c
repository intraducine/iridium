// UI-only simulator harness. Launching Wine is a test error, never a simulated success.
#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>
int iridium_wine_ios_start_embedded_server(int debug, char *error, size_t size) { abort(); }
void iridium_wine_ios_register_guest_thread_signal(int (*callback)(uint64_t, int)) {}
