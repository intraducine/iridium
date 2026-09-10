#include "../MediaSupport/LocalSharedPorts.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    mach_port_t original, found = 42;
    assert(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &original) == KERN_SUCCESS);
    assert(mach_port_insert_right(mach_task_self(), original, original, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS);
    assert(!iridium_port_lookup("missing", &found) && found == MACH_PORT_NULL);
    assert(!iridium_port_register("", original));
    assert(iridium_port_register("texture", original));
    assert(iridium_port_register("texture", original));
    assert(iridium_port_lookup("texture", &found) && found == original);
    mach_port_deallocate(mach_task_self(), found);
    assert(iridium_port_register("texture", MACH_PORT_NULL));
    assert(!iridium_port_lookup("texture", &found));
    mach_port_urefs_t refs;
    assert(mach_port_get_refs(mach_task_self(), original, MACH_PORT_RIGHT_SEND, &refs) == KERN_SUCCESS && refs == 1);
    mach_port_deallocate(mach_task_self(), original);
    mach_port_mod_refs(mach_task_self(), original, MACH_PORT_RIGHT_RECEIVE, -1);
    puts("PASS: lookup, replacement, removal, invalid names, balanced send rights");
}
