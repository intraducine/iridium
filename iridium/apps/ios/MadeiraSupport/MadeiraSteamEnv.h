#pragma once

#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

int madeira_setenv(const char *name, const char *value, int overwrite);

#ifdef __cplusplus
}
#endif

#ifndef MADEIRA_STEAM_ENV_IMPLEMENTATION
#define setenv madeira_setenv
#endif
