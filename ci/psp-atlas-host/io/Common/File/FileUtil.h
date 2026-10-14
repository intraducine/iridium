#pragma once
// Only stdio-backed host paths are needed by the unchanged upstream rasterizer.
#include <cstdio>
#include "Common/File/Path.h"
namespace File {
inline FILE *OpenCFile(const Path &path, const char *mode) { return std::fopen(path.c_str(), mode); }
inline bool Delete(const Path &path) { return std::remove(path.c_str()) == 0; }
}
