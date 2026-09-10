#include "../include/iridium_wine_ios_embedded_server.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

extern void iridium_wineserver_embedded_did_start(void);

int wine_server_embedded;
static atomic_int stop_server;

int wine_server_main(int argc, char *argv[])
{
    struct timespec delay = {0, 1000000};
    (void)argc;
    (void)argv;
    iridium_wineserver_embedded_did_start();
    while (!atomic_load_explicit(&stop_server, memory_order_acquire)) nanosleep(&delay, NULL);
    return 0;
}

int main(void)
{
    char error[256] = {0};
    char server_root[256];

    setenv( "WINEPREFIX", "/tmp/iridium-embedded-prefix-a", 1 );
    snprintf( server_root, sizeof(server_root),
              "/tmp/iridium-embedded-wineserver.%ld", (long)getpid() );
    rmdir( server_root );
    if (mkdir( server_root, 0700 ))
    {
        perror( "mkdir" );
        return 1;
    }
    setenv( "IRIDIUM_WINE_SERVER_ROOT", server_root, 1 );
    if (iridium_wine_ios_start_embedded_server(0, error, sizeof(error)))
    {
        fprintf(stderr, "initial embedded server start failed: %s\n", error);
        return 1;
    }
    if (!wine_server_embedded)
    {
        fprintf(stderr, "embedded server mode was not enabled\n");
        return 1;
    }
    if (iridium_wine_ios_start_embedded_server(0, error, sizeof(error)))
    {
        fprintf(stderr, "idempotent embedded server start failed: %s\n", error);
        return 1;
    }
    setenv( "WINEPREFIX", "/tmp/iridium-embedded-prefix-b", 1 );
    if (iridium_wine_ios_start_embedded_server(0, error, sizeof(error)) != EBUSY)
    {
        fprintf(stderr, "different-prefix embedded server start should fail with EBUSY\n");
        return 1;
    }

    atomic_store_explicit(&stop_server, 1, memory_order_release);
    return 0;
}
