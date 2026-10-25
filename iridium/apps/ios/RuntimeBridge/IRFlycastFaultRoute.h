// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <mach/mach.h>

// Flycast's iOS app sends memory faults to sigaction while JIT BRKs stay with
// the debugger. Save and restore only that exception mask for this session.
struct IRFlycastFaultRoute {
    exception_mask_t masks[EXC_TYPES_COUNT]{};
    mach_port_t ports[EXC_TYPES_COUNT]{};
    exception_behavior_t behaviors[EXC_TYPES_COUNT]{};
    thread_state_flavor_t flavors[EXC_TYPES_COUNT]{};
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    bool active = false;

    bool begin() {
        if (active) return false;
        count = EXC_TYPES_COUNT;
        if (task_swap_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, MACH_PORT_NULL,
            EXCEPTION_DEFAULT, THREAD_STATE_NONE, masks, &count, ports, behaviors, flavors) != KERN_SUCCESS)
            return false;
        active = true;
        return true;
    }
    bool restore() {
        if (!active) return true;
        for (mach_msg_type_number_t i = 0; i < count; ++i)
            if (task_set_exception_ports(mach_task_self(), masks[i], ports[i], behaviors[i], flavors[i]) != KERN_SUCCESS)
                return false;
        for (mach_msg_type_number_t i = 0; i < count; ++i)
            if (MACH_PORT_VALID(ports[i])) mach_port_deallocate(mach_task_self(), ports[i]);
        active = false;
        return true;
    }
};
