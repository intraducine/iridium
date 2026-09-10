#include "../../iridium-wine-ios/iridium/ios/src/iridium_wine_ios_bridge.cpp"

#include "../../iridium-fex-ios/iridium/ios/include/iridium_fex_ios_bridge.h"

#if defined(IRIDIUM_WINE_LINK_EMBEDDED_SERVER)
#include "../../iridium-wine-ios/iridium/ios/include/iridium_wine_ios_embedded_server.h"
#endif

extern "C" void iridium_runtime_host_register_embedded_wine_server_bridge(void)
{
#if defined(IRIDIUM_WINE_LINK_EMBEDDED_SERVER)
    iridium_fex_ios_register_embedded_wine_server_start(
        iridium_wine_ios_start_embedded_server);
    iridium_wine_ios_register_guest_thread_signal(
        iridium_fex_ios_signal_guest_thread);
#else
    iridium_fex_ios_register_embedded_wine_server_start(nullptr);
#endif
}
