/*
 * In-process tracing and notification support for the embedded iOS server.
 *
 * Wine's macOS backend registers a bootstrap service and uses task ports for
 * separate Unix processes. Iridium keeps the server and translated clients in
 * one iOS app process, where those APIs are unavailable and inappropriate.
 */

#include "config.h"

#include <signal.h>

#include "ntstatus.h"
#include "winternl.h"

#include "process.h"
#include "request.h"
#include "thread.h"

#ifdef USE_IRIDIUM_IOS

#include <mach/mach.h>
#include <mach/vm_map.h>

extern int iridium_wineserver_embedded_send_thread_signal( unsigned long long guest_tid, int signal );

void sigchld_callback(void)
{
    /* Embedded clients are host threads, not child Unix processes. */
}

void init_tracing_mechanism(void)
{
}

void init_process_tracing( struct process *process )
{
    process->trace_data = 0;
}

void finish_process_tracing( struct process *process )
{
    process->trace_data = 0;
}

void init_thread_context( struct thread *thread )
{
    (void)thread;
}

void get_thread_context( struct thread *thread, struct context_data *context, unsigned int flags )
{
    (void)thread;
    (void)context;
    (void)flags;
    set_error( STATUS_NOT_SUPPORTED );
}

void set_thread_context( struct thread *thread, const struct context_data *context, unsigned int flags )
{
    (void)thread;
    (void)context;
    (void)flags;
    set_error( STATUS_NOT_SUPPORTED );
}

int send_thread_signal( struct thread *thread, int signal )
{
    if (thread->unix_tid == -1)
    {
        set_error( STATUS_INVALID_CID );
        return 0;
    }
    return iridium_wineserver_embedded_send_thread_signal(
        (unsigned long long)thread->unix_tid, signal ) == 0;
}

int read_process_memory( struct process *process, client_ptr_t ptr, data_size_t size, char *dest )
{
    vm_size_t bytes_read = 0;
    kern_return_t result;

    (void)process;
    result = vm_read_overwrite( mach_task_self(), (vm_address_t)ptr, (vm_size_t)size,
                                (vm_address_t)dest, &bytes_read );
    if (result == KERN_SUCCESS && bytes_read == size) return 1;
    set_error( result == KERN_PROTECTION_FAILURE ? STATUS_ACCESS_DENIED : STATUS_ACCESS_VIOLATION );
    return 0;
}

int write_process_memory( struct process *process, client_ptr_t ptr, data_size_t size,
                          const char *src, data_size_t *written )
{
    kern_return_t result;

    (void)process;
    if (written) *written = 0;
    result = vm_write( mach_task_self(), (vm_address_t)ptr,
                       (vm_offset_t)src, (mach_msg_type_number_t)size );
    if (result == KERN_SUCCESS)
    {
        if (written) *written = size;
        return 1;
    }
    set_error( result == KERN_PROTECTION_FAILURE ? STATUS_ACCESS_DENIED : STATUS_ACCESS_VIOLATION );
    return 0;
}

#endif /* USE_IRIDIUM_IOS */
