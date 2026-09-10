/* Iridium's single-process iOS texture/fence port namespace. */
#include <mach/mach.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct iridium_port_entry {
    char name[128];
    mach_port_t port;
    struct iridium_port_entry *next;
};
static pthread_mutex_t iridium_port_lock = PTHREAD_MUTEX_INITIALIZER;
static struct iridium_port_entry *iridium_ports;

/* ponytail: entries retain ports until unregister or process exit. Cross-process
 * sharing requires an explicit port broker; never treat these names as global. */
static int iridium_port_register(const char *name, mach_port_t port) {
    if (!name || !*name || strnlen(name, 128) == 128) return 0;
    pthread_mutex_lock(&iridium_port_lock);
    struct iridium_port_entry **slot = &iridium_ports;
    while (*slot && strcmp((*slot)->name, name)) slot = &(*slot)->next;
    if (!port) {
        if (*slot) {
            struct iridium_port_entry *old = *slot;
            *slot = old->next;
            mach_port_deallocate(mach_task_self(), old->port);
            free(old);
        }
        pthread_mutex_unlock(&iridium_port_lock); return 1;
    }
    if (mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) {
        pthread_mutex_unlock(&iridium_port_lock); return 0;
    }
    if (!*slot) {
        *slot = calloc(1, sizeof(**slot));
        if (!*slot) {
            mach_port_deallocate(mach_task_self(), port);
            pthread_mutex_unlock(&iridium_port_lock); return 0;
        }
        strcpy((*slot)->name, name);
    } else mach_port_deallocate(mach_task_self(), (*slot)->port);
    (*slot)->port = port;
    pthread_mutex_unlock(&iridium_port_lock); return 1;
}

static int iridium_port_lookup(const char *name, mach_port_t *port) {
    if (!port) return 0;
    *port = MACH_PORT_NULL;
    if (!name || !*name || strnlen(name, 128) == 128) return 0;
    pthread_mutex_lock(&iridium_port_lock);
    struct iridium_port_entry *entry = iridium_ports;
    while (entry && strcmp(entry->name, name)) entry = entry->next;
    if (entry && mach_port_mod_refs(mach_task_self(), entry->port, MACH_PORT_RIGHT_SEND, 1) == KERN_SUCCESS)
        *port = entry->port;
    pthread_mutex_unlock(&iridium_port_lock);
    return *port != MACH_PORT_NULL;
}
