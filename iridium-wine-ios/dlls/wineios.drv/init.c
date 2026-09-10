/*
 * wineios.drv fullscreen-only bridge contract
 */

#include <stdlib.h>
#include <string.h>

#include "iosdrv.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(iosdrv);

const struct wineios_playable_session_contract *wineiosdrv_get_playable_session_contract(void)
{
    static struct wineios_playable_session_contract contract;
    static struct wineios_bridge_configuration configuration;
    char error_buffer[256] = {};

    if (wineiosdrv_load_bridge_configuration(&configuration, error_buffer, sizeof(error_buffer)) != 0)
    {
        WARN("failed to load bridge configuration: %s\n", error_buffer[0] ? error_buffer : "unknown error");
        memset(&configuration, 0, sizeof(configuration));
        strcpy(configuration.graphics_driver, "wineios.drv");
        strcpy(configuration.audio_driver, "winecoreaudio.drv");
        strcpy(configuration.graphics_stack, "metalOpenGLFallback");
        configuration.fullscreen_only = TRUE;
    }

    contract.bridge_config_path = configuration.bridge_config_path[0] ? configuration.bridge_config_path : getenv(IRIDIUM_WINE_IOS_BRIDGE_CONFIG_ENV);
    contract.graphics_driver = configuration.graphics_driver;
    contract.audio_driver = configuration.audio_driver;
    contract.graphics_stack = configuration.graphics_stack;
    contract.surface_identifier = configuration.surface_identifier;
    contract.framebuffer_path = configuration.framebuffer_path;
    contract.input_events_path = configuration.input_events_path;
    contract.audio_state_path = configuration.audio_state_path;
    contract.surface_width = configuration.surface_width;
    contract.surface_height = configuration.surface_height;
    contract.fullscreen_only = configuration.fullscreen_only;

    TRACE(
        "bridge=%s graphics=%s audio=%s surface=%s framebuffer=%s input=%s audio_state=%s size=%ux%u fullscreen_only=%d\n",
        debugstr_a(contract.bridge_config_path),
        debugstr_a(contract.graphics_driver),
        debugstr_a(contract.audio_driver),
        debugstr_a(contract.surface_identifier),
        debugstr_a(contract.framebuffer_path),
        debugstr_a(contract.input_events_path),
        debugstr_a(contract.audio_state_path),
        contract.surface_width,
        contract.surface_height,
        contract.fullscreen_only);

    return &contract;
}
