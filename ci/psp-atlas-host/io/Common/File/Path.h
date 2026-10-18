#pragma once
#include <string>
class Path {
public:
  explicit Path(const char *value) : value_(value) {}
  const char *c_str() const { return value_.c_str(); }
private:
  std::string value_;
};
