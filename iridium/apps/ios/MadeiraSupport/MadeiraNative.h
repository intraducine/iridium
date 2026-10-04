// Iridium adapter declarations, 2026-09-08. Madeira components retain their licenses.
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
@class UIView;
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
extern NSString * const MadeiraDisplayModeChangedNotification;
void winios_screen_size(int *, int *);
void winios_display_mode_changed(int, int);
void winios_cursor_attach(CAMetalLayer * _Nullable);
int winios_reserve_fex_memory(void);
int iridium_reserve_fex_memory(void);
int wineserver_start(const char *);
void wineserver_stop(void);
int wine_process_start(const char *);
void madeira_seed_prefix_if_needed(const char *);
int wine_process_is_running(void);
int wine_process_exit_code(void);
int wineserver_is_running(void);
int wineserver_is_ready(void);
int madeira_request_guest_close(void);
uint64_t madeira_get_present_count(void);
uint64_t winios_surface_present_count(void);
void winios_compositor_attach(UIView * _Nullable);
void winios_set_compositor_frame(double, double, double, double);
void winios_set_desktop_rect(double, double, double, double, int);
int winios_desktop_point_from_window(double, double, int *, int *);
extern NSString * const MadeiraDesktopFramePresentedNotification;
void winios_post_key(int, int);
void winios_post_touch_down(int, int);
void winios_post_touch_move(int, int);
void winios_post_touch_up(int, int);
void winios_pointer(int, int, unsigned int, unsigned int);
extern volatile int ws_log_quiet;
void iridium_profile_enable(int);
uint64_t iridium_profile_take_gap(void);
