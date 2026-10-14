#pragma once
#include <cstring>
#include <string_view>
#include <algorithm>
template<size_t N> inline size_t truncate_cpy(char (&out)[N], std::string_view src) {
  const size_t count = std::min(N - 1, src.size());
  std::memcpy(out, src.data(), count);
  out[count] = 0;
  return count;
}
