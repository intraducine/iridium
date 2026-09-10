// Iridium adapter declarations, 2026-09-08. Madeira components retain their licenses.
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdbool.h>
#include <stdint.h>
bool jit_check_debugged(void);
void jit_install_trap_handler(void);
void *jit26_prepare_region(void *, size_t);
void jit26_detach(void);
bool jit_make_region_no_footprint(void *, size_t, const char *);
void jit_set_log_callback(void (*)(const char *));
void fex_set_log_callback(void (*)(const char *));
void wine_set_ui_log_callback(void (*)(const char *));
void wine_log_set_file(const char *);
void madeira_display_set_layer(CAMetalLayer *);
int wineserver_start(const char *);
void wineserver_stop(void);
int wine_process_start(const char *);
void madeira_seed_prefix_if_needed(const char *);
int wine_process_is_running(void);
uint64_t madeira_get_present_count(void);
void winios_post_key(int, int);
void winios_post_touch_down(int, int);
void winios_post_touch_move(int, int);
void winios_post_touch_up(int, int);
void winios_pointer(int, int, unsigned int, unsigned int);
extern volatile int ws_log_quiet;
void iridium_profile_enable(int);
uint64_t iridium_profile_take_gap(void);
