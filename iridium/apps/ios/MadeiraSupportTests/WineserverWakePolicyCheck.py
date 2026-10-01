from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MadeiraSupport" / "MadeiraRuntimeAdapter.swift").read_text()

policy = 'setenv("MADEIRA_SRV_NOSEM", "0", 0)'
start = 'guard wineserver_start(prefix.path) == 0 else {'

assert source.count(policy) == 1, "expected one default wineserver wake policy"
assert start in source, "wineserver startup call not found"
assert source.index(policy) < source.index(start), "wake policy must be set before wineserver startup"

assert 'setenv("MADEIRA_SRV_NOSEM", "1"' not in source, "fixed polling must remain opt-in"

print("PASS: iOS wineserver defaults to request-triggered wakes; explicit overrides remain intact")

# Exercise the actual native wake/wait branches on the host. This is not an
# iPhone launch test, but catches lost pre-signals, bursts and broken fallback.
if sys.platform == "darwin":
    native = (root.parents[2] / "testrepos/Madeira/build/wineserver/fd_ios.c").read_text()
    wake = native.split("void ios_wineserver_wake(void)", 1)[1].split("\n}", 1)[0] + "\n}"
    wait = native.split("                    if (ios_srv_wake_sem && !nosem)", 1)[1]
    wait = "if (ios_srv_wake_sem && !nosem)" + wait.split("\n                }\n                lt_slept_ns", 1)[0]
    harness = r'''
#include <assert.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <unistd.h>
semaphore_t ios_srv_wake_sem;
unsigned long long ios_c_semto, ios_c_semret;
void ios_wineserver_wake(void) WAKE
static void wait_once(int nosem, unsigned long long sleep_ns) { WAIT }
static unsigned long long now_ns(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}
static void *send_request(void *unused) {
    usleep(5000);
    ios_wineserver_wake();
    return NULL;
}
int main(void) {
    assert(semaphore_create(mach_task_self(), &ios_srv_wake_sem, SYNC_POLICY_FIFO, 0) == KERN_SUCCESS);
    ios_wineserver_wake();
    wait_once(0, 100000000);
    assert(ios_c_semret == 1 && ios_c_semto == 0);
    pthread_t client;
    assert(pthread_create(&client, NULL, send_request, NULL) == 0);
    unsigned long long begin = now_ns();
    wait_once(0, 100000000);
    assert(now_ns() - begin < 90000000 && ios_c_semret == 2);
    assert(pthread_join(client, NULL) == 0);
    for (int i = 0; i < 2048; i++) ios_wineserver_wake();
    for (int i = 0; i < 2048; i++) wait_once(0, 100000000);
    assert(ios_c_semret == 2050);
    wait_once(0, 1000000);
    assert(ios_c_semto == 1);
    ios_wineserver_wake();
    begin = now_ns();
    wait_once(1, 10000000);
    assert(now_ns() - begin >= 5000000 && ios_c_semret == 2051 && ios_c_semto == 2);
    assert(semaphore_destroy(mach_task_self(), ios_srv_wake_sem) == KERN_SUCCESS);
    ios_srv_wake_sem = 0;
    ios_wineserver_wake();
    begin = now_ns();
    wait_once(0, 10000000);
    assert(now_ns() - begin >= 5000000);
    return 0;
}
'''.replace("WAKE", wake).replace("WAIT", wait)
    with tempfile.TemporaryDirectory() as temp:
        source = Path(temp) / "wake.c"
        binary = Path(temp) / "wake"
        source.write_text(harness)
        subprocess.run(["xcrun", "clang", "-Wall", "-Werror", str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=10)
    print("PASS: native Mach wake handles pre-signals, request wakes, bursts, timeout and fixed-sleep fallback")
