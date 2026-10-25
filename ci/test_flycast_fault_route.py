"""Verify Flycast's scoped fault route preserves the shared debugger route."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang++'), 'Apple Mach exception APIs required')
class FlycastFaultRouteTests(unittest.TestCase):
    def test_memory_fault_reaches_sigaction_then_previous_ports_are_restored(self):
        fixture = r'''#include "IRFlycastFaultRoute.h"
#include <cassert>
#include <csignal>
#include <sys/mman.h>
#include <unistd.h>
static void *page;
static volatile sig_atomic_t handled;
static void fault(int, siginfo_t *info, void *) {
    if (info->si_addr == page && !mprotect(page, getpagesize(), PROT_READ | PROT_WRITE)) handled = 1;
    else _exit(2);
}
static mach_port_t port(exception_mask_t mask) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    assert(task_get_exception_ports(mach_task_self(), mask, masks, &count, ports, behaviors, flavors) == KERN_SUCCESS);
    mach_port_t result = count ? ports[0] : MACH_PORT_NULL;
    for (unsigned i = 0; i < count; ++i) if (MACH_PORT_VALID(ports[i])) mach_port_deallocate(mach_task_self(), ports[i]);
    return result;
}
int main() {
    mach_port_t fake;
    assert(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &fake) == KERN_SUCCESS);
    assert(mach_port_insert_right(mach_task_self(), fake, fake, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS);
    assert(task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS | EXC_MASK_BREAKPOINT,
        fake, EXCEPTION_DEFAULT, THREAD_STATE_NONE) == KERN_SUCCESS);
    IRFlycastFaultRoute route;
    assert(route.restore());
    for (int attempt = 0; attempt < 3; ++attempt) {
        assert(route.begin() && !route.begin());
        assert(port(EXC_MASK_BAD_ACCESS) == MACH_PORT_NULL);
        assert(port(EXC_MASK_BREAKPOINT) == fake);
        struct sigaction action{}; action.sa_flags = SA_SIGINFO; action.sa_sigaction = fault;
        assert(!sigaction(SIGBUS, &action, nullptr) && !sigaction(SIGSEGV, &action, nullptr));
        page = mmap(nullptr, getpagesize(), PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
        assert(page != MAP_FAILED); handled = 0;
        (void)*(volatile char *)page;
        assert(handled); assert(!munmap(page, getpagesize()));
        assert(route.restore() && route.restore());
        assert(port(EXC_MASK_BAD_ACCESS) == fake && port(EXC_MASK_BREAKPOINT) == fake);
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'main.cpp'; source.write_text(fixture)
            executable = root / 'check'
            subprocess.run(['clang++', '-std=c++17', '-I', str(ROOT / 'iridium/apps/ios/RuntimeBridge'),
                            str(source), '-o', str(executable)], check=True, timeout=30)
            subprocess.run([str(executable)], check=True, timeout=10)
