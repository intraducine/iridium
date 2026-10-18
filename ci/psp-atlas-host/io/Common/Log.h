#pragma once
// Host-only diagnostics. Keep parser assertions active in Release builds.
#include <cstdio>
#include <cstdlib>
#define ERROR_LOG(channel, ...) do { std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); } while (false)
#define WARN_LOG(channel, ...) ERROR_LOG(channel, __VA_ARGS__)
#define DEBUG_LOG(channel, ...) ERROR_LOG(channel, __VA_ARGS__)
#define _dbg_assert_(condition) do { if (!(condition)) { std::fprintf(stderr, "Atlas parser assertion: %s\n", #condition); std::abort(); } } while (false)
