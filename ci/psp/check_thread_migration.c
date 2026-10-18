// SPDX-License-Identifier: AGPL-3.0-only
#define _DEFAULT_SOURCE
#include "IRPSPBridge.h"
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static int restore_previous(stack_t previous) {
#ifdef __APPLE__
    // Darwin requires MINSIGSTKSZ even when disabling an alternate stack.
    if ((previous.ss_flags & SS_DISABLE) && previous.ss_size < MINSIGSTKSZ)
        previous.ss_size = MINSIGSTKSZ;
#endif
    return sigaltstack(&previous, NULL);
}
static void *close_on_other_thread(void *unused) {
    (void)unused;
    stack_t prior, desired = {.ss_sp=malloc(65536), .ss_size=65536, .ss_flags=0};
    assert(desired.ss_sp && sigaltstack(&desired,&prior) == 0);
    ir_psp_request_stop();
    for (unsigned i=0; i<2000 && ir_psp_phase()!=IR_PSP_CLOSED; ++i) {
        ir_psp_step(0,0,0,NULL); usleep(1000);
    }
    assert(ir_psp_phase()==IR_PSP_CLOSED);
    stack_t after; assert(sigaltstack(NULL,&after)==0);
    assert(after.ss_sp==desired.ss_sp && after.ss_size==desired.ss_size && after.ss_flags==0);
    assert(restore_previous(prior)==0); free(desired.ss_sp); return NULL;
}
int main(int argc,char **argv) {
    assert(argc==5);
    stack_t prior, desired = {.ss_sp=malloc(131072), .ss_size=131072, .ss_flags=0};
    assert(desired.ss_sp && sigaltstack(&desired,&prior)==0);
    for(unsigned cycle=0;cycle<3;++cycle) {
        assert(ir_psp_open(argv[1],argv[2],argv[3],argv[4]));
        for(unsigned i=0;i<2000 && ir_psp_phase()!=IR_PSP_RUNNING;++i) {
            ir_psp_step(0,0,0,NULL); usleep(1000);
        }
        assert(ir_psp_phase()==IR_PSP_RUNNING);
        pthread_t worker; assert(pthread_create(&worker,NULL,close_on_other_thread,NULL)==0);
        assert(pthread_join(worker,NULL)==0);
        stack_t after; assert(sigaltstack(NULL,&after)==0);
        assert(after.ss_sp==desired.ss_sp && after.ss_size==desired.ss_size && after.ss_flags==0);
    }
    assert(restore_previous(prior)==0); free(desired.ss_sp);
    puts("PASS: serial teardown migrates threads while preserving each thread's own alternate signal stack");
}
