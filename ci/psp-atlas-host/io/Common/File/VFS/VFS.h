#pragma once
#include <cstdio>
#include <cstdint>
class HostAtlasVFS {
public:
  uint8_t *ReadFile(const char *name, size_t *length) const {
    FILE *file = std::fopen(name, "rb");
    if (!file) return nullptr;
    if (std::fseek(file, 0, SEEK_END) != 0) { std::fclose(file); return nullptr; }
    long size = std::ftell(file);
    if (size < 0 || std::fseek(file, 0, SEEK_SET) != 0) { std::fclose(file); return nullptr; }
    auto *data = new uint8_t[size];
    if (std::fread(data, 1, size, file) != static_cast<size_t>(size)) {
      delete[] data; std::fclose(file); return nullptr;
    }
    std::fclose(file); *length = size; return data;
  }
};
inline HostAtlasVFS g_VFS;
