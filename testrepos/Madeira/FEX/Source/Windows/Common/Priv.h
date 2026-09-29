// SPDX-License-Identifier: MIT
#pragma once

#include <exception>
#include <winternl.h>

static inline __TEB* GetCurrentTEB() {
  return reinterpret_cast<__TEB*>(NtCurrentTeb());
}

static inline __PEB* GetCurrentPEB() {
  return GetCurrentTEB()->Peb;
}

static inline bool WinAPIReturn(NTSTATUS Status) {
  if (!Status) {
    return true;
  }
  GetCurrentTEB()->LastErrorValue = RtlNtStatusToDosError(Status);
  return false;
}

static inline UNICODE_STRING InitUnicodeString(const wchar_t* String) {
  UNICODE_STRING StringDesc;
  RtlInitUnicodeString(&StringDesc, String);
  return StringDesc;
}

static inline STRING InitAnsiString(const char* String) {
  STRING StringDesc;
  RtlInitAnsiString(&StringDesc, String);
  return StringDesc;
}

class ScopedUnicodeString {
private:
  UNICODE_STRING Str {};
public:
  ScopedUnicodeString() = default;

  ScopedUnicodeString(const char* AStr) {
    RtlCreateUnicodeStringFromAsciiz(&Str, AStr);
  }

  ~ScopedUnicodeString() {
    RtlFreeUnicodeString(&Str);
  }

  UNICODE_STRING* operator->() {
    return &Str;
  }

  UNICODE_STRING& operator*() {
    return Str;
  }
};


/* Encode the stub's source location in the exit status so we can identify
 * which UNIMPLEMENTED was hit. The 16 LSBs of __LINE__ go into bits 0-15;
 * the next 8 bits hash the basename (mostly first letter for disambiguation
 * between IO.cpp/String.cpp/Misc.cpp); 0xFE marks "FEX UNIMPLEMENTED" exits. */
#define UNIMPLEMENTED()                                                       \
  do {                                                                        \
    /* Use __FILE__'s last byte before the extension as a discriminator. */   \
    unsigned _file_tag = (unsigned char)(__FILE__[sizeof(__FILE__) - 6]);     \
    NtTerminateProcess(NtCurrentProcess(),                                    \
        (NTSTATUS)(0xFE000000u | ((_file_tag & 0xFFu) << 16) |                \
                   (__LINE__ & 0xFFFFu)));                                    \
    __fastfail(0);                                                            \
  } while (0)

#define DLLEXPORT_FUNC(Ret, Name, Args) \
  extern "C" Ret Name Args;             \
  Ret(*__imp_##Name) Args = Name;       \
  Ret(*__imp_aux_##Name) Args = Name;   \
  Ret Name Args
