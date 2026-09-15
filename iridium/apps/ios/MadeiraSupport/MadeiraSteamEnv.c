#define MADEIRA_STEAM_ENV_IMPLEMENTATION
#include "MadeiraSteamEnv.h"
#undef setenv

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int madeira_is_steam_identity_key(const char *name) {
    return name &&
        (!strcmp(name, "SteamAppPath") ||
         !strcmp(name, "SteamGameId") ||
         !strcmp(name, "SteamAppId"));
}

int madeira_setenv(const char *name, const char *value, int overwrite) {
    const char *locked = getenv("IRIDIUM_LOCK_STEAM_ENV");
    if (locked && locked[0] == '1' && madeira_is_steam_identity_key(name)) {
        dprintf(STDERR_FILENO,
                "[SteamEnv] blocked legacy native Steam fallback %s=%s\n",
                name ? name : "(null)", value ? value : "(null)");
        return 0;
    }
    return setenv(name, value, overwrite);
}
