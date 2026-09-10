/*
 * wineios.drv Unix sidecar calls
 */

#ifndef __WINE_IOSDRV_UNIXLIB_H
#define __WINE_IOSDRV_UNIXLIB_H

#include "wine/unixlib.h"

enum wineiosdrv_unix_func
{
    wineiosdrv_unix_func_init,
    wineiosdrv_unix_func_count,
};

#define WINEIOSDRV_CALL(func, params) WINE_UNIX_CALL(wineiosdrv_unix_func_ ## func, params)

#endif
