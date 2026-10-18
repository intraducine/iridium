"""Fault-inject the scoped self-task/retained-worker observer without a debugger."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('clang'), 'Darwin C required')
class TeardownObservationTests(unittest.TestCase):
    def compile_and_run(self, fixture):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'main.c').write_text(fixture)
            command = ['clang', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-I', str(BRIDGE),
                       str(root / 'main.c'), '-o', str(root / 'check')]
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(root / 'check')], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())

    def test_scoped_queries_unknown_routes_worker_identity_and_owned_rights(self):
        self.compile_and_run(r'''
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#include <errno.h>
static int mode, rights;
static thread_t self_thread(void) { if(mode==6)return MACH_PORT_NULL; rights++;return mode==16?31:30; }
static kern_return_t drop(mach_port_t task,mach_port_name_t port) { assert(rights>0); rights--; return 0; }
static kern_return_t routes(unsigned kind,exception_mask_array_t masks,mach_msg_type_number_t *count,exception_handler_array_t ports,exception_behavior_array_t behaviors,exception_flavor_array_t flavors) {
    if(mode==(int)kind)return KERN_FAILURE;
    *count=1; masks[0]=EXC_MASK_ALL; ports[0]=MACH_PORT_NULL;
    behaviors[0]=EXCEPTION_DEFAULT; flavors[0]=ARM_THREAD_STATE64;
    if(mode==10)*count=EXC_TYPES_COUNT+1;
    if((mode==11&&kind==1)||(mode==12&&kind==2)){ports[0]=100+kind;rights++;}
    if(mode==13&&kind==1)behaviors[0]++;
    if(mode==14&&kind==2)flavors[0]++;
    if(mode==17){*count=2;masks[1]=masks[0];}
    if(mode==19)ports[0]=MACH_PORT_DEAD;
    if(mode==21)masks[0]=0;
    return KERN_SUCCESS;
}
static kern_return_t task_routes(task_t t,exception_mask_t m,exception_mask_array_t a,mach_msg_type_number_t *n,exception_handler_array_t p,exception_behavior_array_t b,exception_flavor_array_t f){return routes(1,a,n,p,b,f);}
static kern_return_t thread_routes(thread_t t,exception_mask_t m,exception_mask_array_t a,mach_msg_type_number_t *n,exception_handler_array_t p,exception_behavior_array_t b,exception_flavor_array_t f){return routes(2,a,n,p,b,f);}
static kern_return_t query_identity(thread_t t,thread_flavor_t f,thread_info_t out,mach_msg_type_number_t *n){
    if(mode==3)return KERN_FAILURE;
    ((thread_identifier_info_t)out)->thread_id=mode==20?0:t+(mode==15);
    if(mode==4)(*n)--;
    return KERN_SUCCESS;
}
static int trace(int *name,u_int count,void *out,size_t *size,void *in,size_t in_size){
    if(mode==7){errno=EACCES;return -1;}
    struct kinfo_proc *p=out;memset(p,0,*size);
    if(mode==8)(*size)--; if(mode==9)p->kp_proc.p_flag=P_TRACED;if(mode==18)*size=SIZE_MAX;return 0;
}
static void *alloc(size_t n,size_t size){if(mode==5){errno=ENOMEM;return NULL;}return calloc(n,size);}
#define mach_thread_self self_thread
#define mach_port_deallocate drop
#define task_get_exception_ports task_routes
#define thread_get_exception_ports thread_routes
#define thread_info query_identity
#define sysctl trace
#define calloc alloc
#define mach_host_self(...) (abort(),0)
#define host_get_exception_ports(...) (abort(),KERN_FAILURE)
#define task_threads(...) (abort(),KERN_FAILURE)
#include "IRPSPTeardownObservation.c"
#undef calloc
int main(void){
    IRPSPTeardownObservation *before=ir_psp_teardown_capture();assert(before&&rights==1);
    assert(ir_psp_teardown_matches(before)&&rights==1);
    for(mode=13;mode<=16;mode++){
        IRPSPObservationDiagnostic result={0};assert(!ir_psp_teardown_matches_diagnostic(before,&result));
        assert(result.failure==(mode<15?IR_PSP_OBSERVATION_ROUTING_MISMATCH:IR_PSP_OBSERVATION_WORKER_MISMATCH));assert(rights==1);
    }
    mode=0;ir_psp_teardown_free(before);assert(rights==0);
    const struct {int mode;IRPSPObservationFailure kind;int code;unsigned count;} failures[]={
        {1,IR_PSP_OBSERVATION_TASK_ROUTES,KERN_FAILURE,EXC_TYPES_COUNT},
        {2,IR_PSP_OBSERVATION_THREAD_ROUTES,KERN_FAILURE,EXC_TYPES_COUNT},
        {3,IR_PSP_OBSERVATION_THREAD_IDENTITY,KERN_FAILURE,THREAD_IDENTIFIER_INFO_COUNT},
        {4,IR_PSP_OBSERVATION_THREAD_IDENTITY_COUNT,0,THREAD_IDENTIFIER_INFO_COUNT-1},
        {5,IR_PSP_OBSERVATION_ALLOCATION,ENOMEM,0},{6,IR_PSP_OBSERVATION_WORKER_PORT,0,0},
        {7,IR_PSP_OBSERVATION_TRACE_QUERY,EACCES,sizeof(struct kinfo_proc)},
        {8,IR_PSP_OBSERVATION_TRACE_SIZE,0,sizeof(struct kinfo_proc)-1},{9,IR_PSP_OBSERVATION_TRACED,0,0},
        {10,IR_PSP_OBSERVATION_ROUTE_COUNT,0,EXC_TYPES_COUNT+1},
        {11,IR_PSP_OBSERVATION_UNKNOWN_ROUTE,0,1},{12,IR_PSP_OBSERVATION_UNKNOWN_ROUTE,0,1},
        {17,IR_PSP_OBSERVATION_ROUTE_COUNT,0,2},{18,IR_PSP_OBSERVATION_TRACE_SIZE,0,65535},
        {19,IR_PSP_OBSERVATION_UNKNOWN_ROUTE,0,1},
        {20,IR_PSP_OBSERVATION_THREAD_IDENTITY_COUNT,0,THREAD_IDENTIFIER_INFO_COUNT},
        {21,IR_PSP_OBSERVATION_ROUTE_COUNT,0,1}
    };
    for(unsigned i=0;i<sizeof failures/sizeof *failures;i++){
        mode=failures[i].mode;IRPSPObservationDiagnostic result={0};assert(!ir_psp_teardown_capture_diagnostic(&result));
        assert(rights==0&&result.failure==failures[i].kind&&result.code==failures[i].code&&result.count==failures[i].count);
    }
    mode=7;IRPSPObservationDiagnostic first={0};assert(!ir_psp_teardown_capture_diagnostic(&first));
    mode=5;assert(!ir_psp_teardown_capture_diagnostic(&first));assert(first.failure==IR_PSP_OBSERVATION_TRACE_QUERY&&first.code==EACCES&&rights==0);
    puts("PASS scoped observer: failed/short self queries, unknown live/dead handlers, malformed route counts, changed routes and replaced worker refuse; copied rights released; host/all-thread APIs forbidden");
}
''')

    def test_real_self_getters_and_thread_churn(self):
        self.compile_and_run(r'''
#include <pthread.h>
#include <assert.h>
#include <stdio.h>
#include "IRPSPTeardownObservation.c"
static void *other(void *value){
    IRPSPObservationDiagnostic result={0};
    assert(!ir_psp_teardown_matches_diagnostic(value,&result));
    assert(result.failure==IR_PSP_OBSERVATION_WORKER_MISMATCH || result.failure==IR_PSP_OBSERVATION_UNKNOWN_ROUTE);
    return NULL;
}
int main(void){
    IRPSPObservationDiagnostic result={0};IRPSPTeardownObservation *before=ir_psp_teardown_capture_diagnostic(&result);
    if(!before){assert(result.failure==IR_PSP_OBSERVATION_UNKNOWN_ROUTE);puts("PASS actual self getters: unrecognized explicit handler refused");return 0;}
    assert(ir_psp_teardown_matches(before));
    for(unsigned i=0;i<8;i++){pthread_t t;assert(!pthread_create(&t,NULL,other,before));assert(!pthread_join(t,NULL));assert(ir_psp_teardown_matches(before));}
    ir_psp_teardown_free(before);
    puts("PASS actual ordinary-process self getters: same worker matches; another worker refuses; unrelated thread churn preserves the baseline");
}
''')


if __name__ == '__main__':
    unittest.main()
