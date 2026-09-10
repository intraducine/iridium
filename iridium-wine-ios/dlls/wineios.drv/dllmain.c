/*
 * wineios.drv entry points
 */

#include <stdarg.h>

#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "iosdrv.h"
#include "unixlib.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(iosdrv);

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    TRACE("wineios.drv DllMain reason=%lu reserved=%p\n", reason, reserved);

    switch (reason)
    {
    case DLL_PROCESS_ATTACH:
        wineiosdrv_trace("wineios.drv PE DllMain process attach");
        DisableThreadLibraryCalls(instance);
        if (__wine_init_unix_call())
        {
            wineiosdrv_trace("wineios.drv PE unix call init failed");
            return FALSE;
        }
        wineiosdrv_trace("wineios.drv PE unix call init succeeded");
        if (WINEIOSDRV_CALL(init, NULL))
        {
            wineiosdrv_trace("wineios.drv PE unix init callback failed");
            return FALSE;
        }
        wineiosdrv_trace("wineios.drv PE unix init callback succeeded");
        return TRUE;
    case DLL_PROCESS_DETACH:
        break;
    }

    return TRUE;
}
