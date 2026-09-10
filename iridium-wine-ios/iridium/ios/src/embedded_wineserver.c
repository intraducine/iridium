/*
 * Native, in-process Wine server lifecycle for iOS hosts.
 *
 * iOS cannot execute the packaged Linux/x86-64 wineserver. The guest Wine
 * loader reaches this entry point through Iridium's FEX syscall bridge and
 * resumes only after Wine's native server initialization is complete.
 */

#include "../include/iridium_wine_ios_embedded_server.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

extern int wine_server_main( int argc, char *argv[] );
extern int wine_server_embedded;

enum embedded_server_state
{
    EMBEDDED_SERVER_IDLE,
    EMBEDDED_SERVER_STARTING,
    EMBEDDED_SERVER_RUNNING,
    EMBEDDED_SERVER_FAILED
};

static pthread_mutex_t server_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t server_condition = PTHREAD_COND_INITIALIZER;
static enum embedded_server_state server_state = EMBEDDED_SERVER_IDLE;
static int server_debug_enabled;
static int server_failure = EIO;
static char server_prefix[PATH_MAX];
static _Atomic(IridiumWineIOSGuestThreadSignal) guest_thread_signal;

static void copy_error( char *buffer, size_t size, const char *message )
{
    if (!buffer || !size) return;
    snprintf( buffer, size, "%s", message );
}

void iridium_wine_ios_register_guest_thread_signal(
    IridiumWineIOSGuestThreadSignal callback )
{
    atomic_store_explicit( &guest_thread_signal, callback, memory_order_release );
}

int iridium_wineserver_embedded_send_thread_signal(
    unsigned long long guest_tid, int signal )
{
    IridiumWineIOSGuestThreadSignal callback =
        atomic_load_explicit( &guest_thread_signal, memory_order_acquire );
    if (!callback) return ENOSYS;
    return callback( (uint64_t)guest_tid, signal );
}

void iridium_wineserver_embedded_did_start(void)
{
    pthread_mutex_lock( &server_mutex );
    server_state = EMBEDDED_SERVER_RUNNING;
    server_failure = 0;
    pthread_cond_broadcast( &server_condition );
    pthread_mutex_unlock( &server_mutex );
}

static void embedded_server_thread_cleanup( void *unused )
{
    (void)unused;
    pthread_mutex_lock( &server_mutex );
    server_state = EMBEDDED_SERVER_FAILED;
    if (!server_failure) server_failure = EPIPE;
    pthread_cond_broadcast( &server_condition );
    pthread_mutex_unlock( &server_mutex );
}

static void *embedded_server_thread( void *unused )
{
    char *argv[5];
    int argc = 0;

    (void)unused;
    argv[argc++] = (char *)"iridium-wineserver";
    argv[argc++] = (char *)"-f";
    argv[argc++] = (char *)"-p";  /* stay alive for the containing app */
    if (server_debug_enabled) argv[argc++] = (char *)"-d";
    argv[argc] = NULL;

    pthread_cleanup_push( embedded_server_thread_cleanup, NULL );
    server_failure = wine_server_main( argc, argv ) ? EIO : 0;
    pthread_cleanup_pop( 1 );
    return NULL;
}

static void startup_deadline( struct timespec *deadline )
{
    clock_gettime( CLOCK_REALTIME, deadline );
    deadline->tv_sec += 15;
}

int iridium_wine_ios_start_embedded_server(
    int debug_enabled,
    char *error_buffer,
    size_t error_buffer_size )
{
    const char *requested_prefix = getenv( "WINEPREFIX" );
    const char *server_root = getenv( "IRIDIUM_WINE_SERVER_ROOT" );
    pthread_t thread;
    struct timespec deadline;
    int error = 0;

    if (!server_root || server_root[0] != '/')
    {
        copy_error( error_buffer, error_buffer_size,
                    "IRIDIUM_WINE_SERVER_ROOT must be an absolute sandbox-writable path" );
        return EINVAL;
    }
    if (mkdir( server_root, 0700 ) && errno != EEXIST)
    {
        error = errno;
        copy_error( error_buffer, error_buffer_size,
                    "could not create the sandbox-writable Wine server root" );
        return error;
    }
    if (access( server_root, W_OK | X_OK ))
    {
        error = errno;
        copy_error( error_buffer, error_buffer_size,
                    "Wine server root is not writable inside the app sandbox" );
        return error;
    }

    if (requested_prefix && strlen( requested_prefix ) >= sizeof(server_prefix))
    {
        copy_error( error_buffer, error_buffer_size, "Wine prefix path is too long for the embedded server" );
        return ENAMETOOLONG;
    }
    pthread_mutex_lock( &server_mutex );
    if (server_state != EMBEDDED_SERVER_IDLE && server_prefix[0]
        && (!requested_prefix || strcmp( server_prefix, requested_prefix )))
    {
        copy_error( error_buffer, error_buffer_size,
                    "embedded Wine server is already bound to another prefix; restart Iridium before launching this game" );
        pthread_mutex_unlock( &server_mutex );
        return EBUSY;
    }
    if (server_state == EMBEDDED_SERVER_RUNNING)
    {
        pthread_mutex_unlock( &server_mutex );
        return 0;
    }

    if (server_state == EMBEDDED_SERVER_FAILED)
    {
        error = server_failure ? server_failure : EIO;
        copy_error( error_buffer, error_buffer_size, "embedded Wine server previously failed" );
        pthread_mutex_unlock( &server_mutex );
        return error;
    }

    if (server_state == EMBEDDED_SERVER_IDLE)
    {
        server_state = EMBEDDED_SERVER_STARTING;
        server_debug_enabled = debug_enabled != 0;
        if (requested_prefix) snprintf( server_prefix, sizeof(server_prefix), "%s", requested_prefix );
        wine_server_embedded = 1;
        error = pthread_create( &thread, NULL, embedded_server_thread, NULL );
        if (error)
        {
            server_state = EMBEDDED_SERVER_FAILED;
            server_failure = error;
            copy_error( error_buffer, error_buffer_size, "could not create embedded Wine server thread" );
            pthread_mutex_unlock( &server_mutex );
            return error;
        }
        pthread_detach( thread );
    }

    startup_deadline( &deadline );
    while (server_state == EMBEDDED_SERVER_STARTING)
    {
        error = pthread_cond_timedwait( &server_condition, &server_mutex, &deadline );
        if (error == ETIMEDOUT)
        {
            copy_error( error_buffer, error_buffer_size, "embedded Wine server startup timed out before its request socket became ready" );
            pthread_mutex_unlock( &server_mutex );
            return ETIMEDOUT;
        }
    }

    if (server_state == EMBEDDED_SERVER_RUNNING)
    {
        pthread_mutex_unlock( &server_mutex );
        return 0;
    }

    error = server_failure ? server_failure : EIO;
    copy_error( error_buffer, error_buffer_size, "embedded Wine server stopped during startup" );
    pthread_mutex_unlock( &server_mutex );
    return error;
}
