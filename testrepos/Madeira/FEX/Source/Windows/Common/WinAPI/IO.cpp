// SPDX-License-Identifier: MIT
#define NTDDI_VERSION 0x0A000005
#define WINAPI
#define WINBASEAPI

#include <cstdlib>
#include <cstdio>
#include <cstdint>
#include <cerrno>
#include <winternl.h>
#include <windows.h>
#include <processenv.h>
#include <wine/debug.h>
#include "../Priv.h"

namespace {
ULONG CreateDispositionToNT(DWORD Disposition) {
  switch (Disposition) {
  case CREATE_ALWAYS: return FILE_OVERWRITE_IF;
  case CREATE_NEW: return FILE_CREATE;
  case TRUNCATE_EXISTING: return FILE_OVERWRITE;
  case OPEN_ALWAYS: return FILE_OPEN_IF;
  case OPEN_EXISTING: return FILE_OPEN;
  default: UNIMPLEMENTED();
  }
}

ULONG OpenFlagsToNT(DWORD Flags) {
  ULONG NTFlags = 0;
  NTFlags |= (Flags & FILE_FLAG_BACKUP_SEMANTICS) ? FILE_OPEN_FOR_BACKUP_INTENT : 0;
  NTFlags |= (Flags & FILE_FLAG_DELETE_ON_CLOSE) ? FILE_DELETE_ON_CLOSE : 0;
  NTFlags |= (Flags & FILE_FLAG_NO_BUFFERING) ? FILE_NO_INTERMEDIATE_BUFFERING : 0;
  NTFlags |= (Flags & FILE_FLAG_RANDOM_ACCESS) ? FILE_RANDOM_ACCESS : 0;
  NTFlags |= (Flags & FILE_FLAG_SEQUENTIAL_SCAN) ? FILE_SEQUENTIAL_ONLY : 0;
  NTFlags |= (Flags & FILE_FLAG_WRITE_THROUGH) ? FILE_WRITE_THROUGH : 0;
  return NTFlags;
}

FILE_INFORMATION_CLASS FileInfoClassToNT(FILE_INFO_BY_HANDLE_CLASS InformationClass) {
  switch (InformationClass) {
  case FileBasicInfo: return FileBasicInformation;
  case FileStandardInfo: return FileStandardInformation;
  default: UNIMPLEMENTED();
  }
}
} // namespace

DLLEXPORT_FUNC(BOOL, DeleteFileA, (LPCSTR lpFileName)) {
  ScopedUnicodeString FileName {lpFileName};
  return DeleteFileW(FileName->Buffer);
}

DLLEXPORT_FUNC(BOOL, DeleteFileW, (LPCWSTR lpFileName)) {
  UNICODE_STRING PathW;
  RtlInitUnicodeString(&PathW, lpFileName);

  ScopedUnicodeString NTPath;
  if (!RtlDosPathNameToNtPathName_U(PathW.Buffer, &*NTPath, nullptr, nullptr)) {
    SetLastError(ERROR_PATH_NOT_FOUND);
    return false;
  }

  OBJECT_ATTRIBUTES ObjAttributes;
  InitializeObjectAttributes(&ObjAttributes, &*NTPath, OBJ_CASE_INSENSITIVE, nullptr, nullptr);

  HANDLE Handle;
  IO_STATUS_BLOCK IOSB;

  NTSTATUS Status =
    NtCreateFile(&Handle, SYNCHRONIZE | DELETE, &ObjAttributes, &IOSB, nullptr, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                 FILE_OPEN, FILE_DELETE_ON_CLOSE | FILE_NON_DIRECTORY_FILE, nullptr, 0);
  if (WinAPIReturn(Status)) {
    Status = NtClose(Handle);
  }

  return WinAPIReturn(Status);
}

DLLEXPORT_FUNC(HANDLE, CreateFileA,
               (LPCSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, LPSECURITY_ATTRIBUTES lpSecurityAttributes,
                DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile)) {

  ScopedUnicodeString FileName {lpFileName};
  return CreateFileW(FileName->Buffer, dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes,
                     hTemplateFile);
}

DLLEXPORT_FUNC(HANDLE, CreateFileW,
               (LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, LPSECURITY_ATTRIBUTES lpSecurityAttributes,
                DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile)) {
  UNICODE_STRING PathW;
  RtlInitUnicodeString(&PathW, lpFileName);

  ScopedUnicodeString NTPath;
  if (!RtlDosPathNameToNtPathName_U(PathW.Buffer, &*NTPath, nullptr, nullptr)) {
    SetLastError(ERROR_PATH_NOT_FOUND);
    return INVALID_HANDLE_VALUE;
  }

  OBJECT_ATTRIBUTES ObjAttributes;
  InitializeObjectAttributes(&ObjAttributes, &*NTPath, OBJ_CASE_INSENSITIVE, nullptr, nullptr);

  HANDLE Handle;
  IO_STATUS_BLOCK IOSB;
  NTSTATUS Status =
    NtCreateFile(&Handle, dwDesiredAccess | GENERIC_READ | SYNCHRONIZE, &ObjAttributes, &IOSB, nullptr, OpenFlagsToNT(dwFlagsAndAttributes),
                 dwShareMode, CreateDispositionToNT(dwCreationDisposition), FILE_SYNCHRONOUS_IO_NONALERT, nullptr, 0);
  return WinAPIReturn(Status) ? Handle : INVALID_HANDLE_VALUE;
}

DLLEXPORT_FUNC(WINBOOL, WriteFile,
               (HANDLE hFile, const void* lpBuffer, DWORD nNumberOfBytesToWrite, LPDWORD lpNumberOfBytesWritten, LPOVERLAPPED lpOverlapped)) {
  IO_STATUS_BLOCK IOSB;
  if (lpOverlapped) {
    UNIMPLEMENTED();
  }
  /* iOS-Madeira ml572: WriteFile TRACING BLOCK REMOVED — it was a stack smash.
   *
   * It formatted into `char dbg[8 + 64 + 16]` (88 bytes) but wrote a 38-byte
   * header plus up to 64 preview bytes, each of which could expand to 2 chars
   * for '\n', plus a trailing newline: 103 bytes for ordinary text and 167 in
   * the worst case. Any WriteFile whose payload was >= 50 bytes overflowed, and
   * the compiler had placed the callee-saved registers immediately after it
   * (dbg at sp+0x18, saved x19 at sp+0x70 — exactly 88 bytes later, x20 at
   * sp+0x78). So the overflow wrote the log text straight onto the caller's
   * saved x20, and on return the caller's `blr x20` jumped into ASCII.
   *
   * Proven byte-for-byte across four runs: ml571 faulted at pc=0xa336531373030,
   * which is the little-endian bytes "0071e3\n\0" — the tail of the rpm-poison
   * record being written at that moment. ml483a/ml484a/mlf show the same shape
   * with 0071e0/0071e1/0071e2. Diagnosis by Sol.
   *
   * The fault then landed while FEX's CodeInvalidationMutex was held, and the
   * guest redirect bypassed the RAII unlock — leaving one leaked reader and one
   * waiting writer, which stops compilation dead. That is the [deliver-hold]
   * "leaks the read hold" line and the whole-app freeze.
   *
   * Deleted rather than enlarged: this is a hot path on every guest write, the
   * output was going to a guest stderr handle we rarely read, and a fixed-size
   * formatter here has now cost more than it ever explained. */
  NTSTATUS Status = NtWriteFile(hFile, nullptr, nullptr, nullptr, &IOSB, lpBuffer, nNumberOfBytesToWrite, nullptr, nullptr);
  if (lpNumberOfBytesWritten) {
    *lpNumberOfBytesWritten = static_cast<DWORD>(IOSB.Information);
  }
  return WinAPIReturn(Status);
}

DLLEXPORT_FUNC(HANDLE, GetStdHandle, (DWORD nStdHandle)) {
  auto* Params = reinterpret_cast<RTL_USER_PROCESS_PARAMETERS64*>(NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters);
  switch (nStdHandle) {
  case STD_INPUT_HANDLE: return reinterpret_cast<HANDLE>(Params->hStdInput);
  case STD_OUTPUT_HANDLE: return reinterpret_cast<HANDLE>(Params->hStdOutput);
  case STD_ERROR_HANDLE: return reinterpret_cast<HANDLE>(Params->hStdError);
  default:
    SetLastError(ERROR_INVALID_HANDLE);
    return INVALID_HANDLE_VALUE;
  }
}

DLLEXPORT_FUNC(WINBOOL, WriteConsoleA,
               (HANDLE hConsoleOutput, CONST void* lpBuffer, DWORD nNumberOfCharsToWrite, LPDWORD lpNumberOfCharsWritten, void* lpReserved)) {
  IO_STATUS_BLOCK IOSB;
  NTSTATUS Status = NtWriteFile(hConsoleOutput, nullptr, nullptr, nullptr, &IOSB, lpBuffer, nNumberOfCharsToWrite, nullptr, nullptr);
  if (lpNumberOfCharsWritten) {
    *lpNumberOfCharsWritten = static_cast<DWORD>(IOSB.Information);
  }
  return WinAPIReturn(Status);
}

extern "C" NTSTATUS NTAPI RtlUnicodeToUTF8N(char* dst, ULONG dstlen, ULONG* reslen, const WCHAR* src, ULONG srclen);

DLLEXPORT_FUNC(WINBOOL, WriteConsoleW,
               (HANDLE hConsoleOutput, CONST void* lpBuffer, DWORD nNumberOfCharsToWrite, LPDWORD lpNumberOfCharsWritten, void* lpReserved)) {
  ULONG utf8_len = 0;
  RtlUnicodeToUTF8N(nullptr, 0, &utf8_len, static_cast<const WCHAR*>(lpBuffer), nNumberOfCharsToWrite * sizeof(WCHAR));
  if (utf8_len == 0) {
    if (lpNumberOfCharsWritten) *lpNumberOfCharsWritten = 0;
    return TRUE;
  }
  auto* utf8 = static_cast<char*>(RtlAllocateHeap(GetProcessHeap(), 0, utf8_len));
  if (!utf8) return FALSE;
  ULONG written = 0;
  RtlUnicodeToUTF8N(utf8, utf8_len, &written, static_cast<const WCHAR*>(lpBuffer), nNumberOfCharsToWrite * sizeof(WCHAR));

  IO_STATUS_BLOCK IOSB;
  NTSTATUS Status = NtWriteFile(hConsoleOutput, nullptr, nullptr, nullptr, &IOSB, utf8, written, nullptr, nullptr);
  RtlFreeHeap(GetProcessHeap(), 0, utf8);
  if (lpNumberOfCharsWritten) {
    *lpNumberOfCharsWritten = nNumberOfCharsToWrite;
  }
  return WinAPIReturn(Status);
}

DLLEXPORT_FUNC(WINBOOL, SetFilePointerEx, (HANDLE hFile, LARGE_INTEGER liDistanceToMove, PLARGE_INTEGER lpNewFilePointer, DWORD dwMoveMethod)) {
  IO_STATUS_BLOCK IOSB;
  FILE_POSITION_INFORMATION PositionInfo;
  if (NTSTATUS Status = NtQueryInformationFile(hFile, &IOSB, &PositionInfo, sizeof(PositionInfo), FilePositionInformation); Status) {
    return WinAPIReturn(Status);
  }
  FILE_STANDARD_INFORMATION StandardInfo;
  if (NTSTATUS Status = NtQueryInformationFile(hFile, &IOSB, &StandardInfo, sizeof(StandardInfo), FileStandardInformation); Status) {
    return WinAPIReturn(Status);
  }

  switch (dwMoveMethod) {
  case FILE_BEGIN: PositionInfo.CurrentByteOffset = liDistanceToMove; break;
  case FILE_CURRENT: PositionInfo.CurrentByteOffset.QuadPart += liDistanceToMove.QuadPart; break;
  case FILE_END: PositionInfo.CurrentByteOffset = StandardInfo.EndOfFile; break;
  default: UNIMPLEMENTED();
  }
  if (NTSTATUS Status = NtSetInformationFile(hFile, &IOSB, &PositionInfo, sizeof(PositionInfo), FilePositionInformation); Status) {
    return WinAPIReturn(Status);
  }
  if (lpNewFilePointer) {
    *lpNewFilePointer = PositionInfo.CurrentByteOffset;
  }
  return true;
}

DLLEXPORT_FUNC(WINBOOL, ReadFile,
               (HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesToRead, LPDWORD lpNumberOfBytesRead, LPOVERLAPPED lpOverlapped)) {
  IO_STATUS_BLOCK IOSB;
  if (lpOverlapped) {
    UNIMPLEMENTED();
  }
  NTSTATUS Status = NtReadFile(hFile, nullptr, nullptr, nullptr, &IOSB, lpBuffer, nNumberOfBytesToRead, nullptr, nullptr);
  if (lpNumberOfBytesRead) {
    *lpNumberOfBytesRead = static_cast<DWORD>(IOSB.Information);
  }
  return WinAPIReturn(Status);
}

DLLEXPORT_FUNC(WINBOOL, FlushFileBuffers, (HANDLE hFile)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(DWORD, GetFinalPathNameByHandleA, (HANDLE hFile, LPSTR lpszFilePath, DWORD cchFilePath, DWORD dwFlags)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(DWORD, GetFinalPathNameByHandleW, (HANDLE hFile, LPWSTR lpszFilePath, DWORD cchFilePath, DWORD dwFlags)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, CreateHardLinkA, (LPCSTR lpFileName, LPCSTR lpExistingFileName, LPSECURITY_ATTRIBUTES lpSecurityAttributes)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, CreateHardLinkW, (LPCWSTR lpFileName, LPCWSTR lpExistingFileName, LPSECURITY_ATTRIBUTES lpSecurityAttributes)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, CreateDirectoryA, (LPCSTR lpPathName, LPSECURITY_ATTRIBUTES lpSecurityAttributes)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, CreateDirectoryW, (LPCWSTR lpPathName, LPSECURITY_ATTRIBUTES lpSecurityAttributes)) {
  UNICODE_STRING PathW;
  RtlInitUnicodeString(&PathW, lpPathName);

  ScopedUnicodeString NTPath;
  if (!RtlDosPathNameToNtPathName_U(PathW.Buffer, &*NTPath, nullptr, nullptr)) {
    SetLastError(ERROR_PATH_NOT_FOUND);
    return false;
  }

  OBJECT_ATTRIBUTES ObjAttributes;
  InitializeObjectAttributes(&ObjAttributes, &*NTPath, OBJ_CASE_INSENSITIVE, nullptr, nullptr);

  HANDLE Handle;
  IO_STATUS_BLOCK IOSB;
  NTSTATUS Status = NtCreateFile(&Handle, GENERIC_READ | SYNCHRONIZE, &ObjAttributes, &IOSB, nullptr, FILE_ATTRIBUTE_NORMAL,
                                 FILE_SHARE_READ, FILE_CREATE, FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT, nullptr, 0);
  return WinAPIReturn(Status);
}

DLLEXPORT_FUNC(WINBOOL, GetFileInformationByHandle, (HANDLE hFile, LPBY_HANDLE_FILE_INFORMATION lpFileInformation)) {
  FILE_BASIC_INFO BasicInfo;
  if (!GetFileInformationByHandleEx(hFile, FileBasicInfo, &BasicInfo, sizeof(BasicInfo))) {
    return false;
  }
  FILE_STANDARD_INFO StandardInfo;
  if (!GetFileInformationByHandleEx(hFile, FileStandardInfo, &StandardInfo, sizeof(StandardInfo))) {
    return false;
  }

  *lpFileInformation = BY_HANDLE_FILE_INFORMATION {
    .dwFileAttributes = BasicInfo.FileAttributes,
    .ftCreationTime = {static_cast<DWORD>(BasicInfo.CreationTime.LowPart), static_cast<DWORD>(BasicInfo.CreationTime.HighPart)},
    .ftLastAccessTime = {static_cast<DWORD>(BasicInfo.LastAccessTime.LowPart), static_cast<DWORD>(BasicInfo.LastAccessTime.HighPart)},
    .ftLastWriteTime = {static_cast<DWORD>(BasicInfo.LastWriteTime.LowPart), static_cast<DWORD>(BasicInfo.LastWriteTime.HighPart)},
    .dwVolumeSerialNumber = 0,
    .nFileSizeHigh = static_cast<DWORD>(StandardInfo.EndOfFile.HighPart),
    .nFileSizeLow = static_cast<DWORD>(StandardInfo.EndOfFile.LowPart),
    .nNumberOfLinks = StandardInfo.NumberOfLinks,
    .nFileIndexHigh = 0,
    .nFileIndexLow = 0};
  return true;
}

DLLEXPORT_FUNC(WINBOOL, SetFileInformationByHandle,
               (HANDLE hFile, FILE_INFO_BY_HANDLE_CLASS FileInformationClass, void* lpFileInformation, DWORD dwBufferSize)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, SetEndOfFile, (HANDLE hFile)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(DWORD, GetFileAttributesA, (LPCSTR lpFileName)) {
  /* iOS-Madeira stub: pretend the file doesn't exist so FEX's config-file
   * lookups (FEX::Config::LoadConfig etc.) skip cleanly. */
  SetLastError(ERROR_FILE_NOT_FOUND);
  return INVALID_FILE_ATTRIBUTES;
}

DLLEXPORT_FUNC(DWORD, GetFileAttributesW, (LPCWSTR lpFileName)) {
  SetLastError(ERROR_FILE_NOT_FOUND);
  return INVALID_FILE_ATTRIBUTES;
}

DLLEXPORT_FUNC(WINBOOL, SetFileAttributesA, (LPCSTR lpFileName, DWORD dwFileAttributes)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, SetFileAttributesW, (LPCWSTR lpFileName, DWORD dwFileAttributes)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, SetFileTime,
               (HANDLE hFile, CONST FILETIME* lpCreationTime, CONST FILETIME* lpLastAccessTime, CONST FILETIME* lpLastWriteTime)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, MoveFileExA, (LPCSTR lpExistingFileName, LPCSTR lpNewFileName, DWORD dwFlags)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, MoveFileExW, (LPCWSTR lpExistingFileName, LPCWSTR lpNewFileName, DWORD dwFlags)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, GetDiskFreeSpaceExA,
               (LPCSTR lpDirectoryName, PULARGE_INTEGER lpFreeBytesAvailableToCaller, PULARGE_INTEGER lpTotalNumberOfBytes,
                PULARGE_INTEGER lpTotalNumberOfFreeBytes)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, GetDiskFreeSpaceExW,
               (LPCWSTR lpDirectoryName, PULARGE_INTEGER lpFreeBytesAvailableToCaller, PULARGE_INTEGER lpTotalNumberOfBytes,
                PULARGE_INTEGER lpTotalNumberOfFreeBytes)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(DWORD, GetTempPathA, (DWORD nBufferLength, LPSTR lpBuffer)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(DWORD, GetTempPathW, (DWORD nBufferLength, LPWSTR lpBuffer)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(BOOLEAN, CreateSymbolicLinkA, (LPCSTR lpSymlinkFileName, LPCSTR lpTargetFileName, DWORD dwFlags)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(BOOLEAN, CreateSymbolicLinkW, (LPCWSTR lpSymlinkFileName, LPCWSTR lpTargetFileName, DWORD dwFlags)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, AreFileApisANSI, ()) {
  return true;
}

DLLEXPORT_FUNC(WINBOOL, FindNextFileA, (HANDLE hFindFile, LPWIN32_FIND_DATAA lpFindFileData)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, FindNextFileW, (HANDLE hFindFile, LPWIN32_FIND_DATAW lpFindFileData)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, FindClose, (HANDLE hFindFile)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(HANDLE, FindFirstFileA, (LPCSTR lpFileName, LPWIN32_FIND_DATAA lpFindFileData)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(HANDLE, FindFirstFileW, (LPCWSTR lpFileName, LPWIN32_FIND_DATAW lpFindFileData)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, DeviceIoControl,
               (HANDLE hDevice, DWORD dwIoControlCode, void* lpInBuffer, DWORD nInBufferSize, void* lpOutBuffer, DWORD nOutBufferSize,
                LPDWORD lpBytesReturned, LPOVERLAPPED lpOverlapped)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, GetFileInformationByHandleEx,
               (HANDLE hFile, FILE_INFO_BY_HANDLE_CLASS FileInformationClass, void* lpFileInformation, DWORD dwBufferSize)) {
  IO_STATUS_BLOCK IOSB;
  return WinAPIReturn(NtQueryInformationFile(hFile, &IOSB, lpFileInformation, dwBufferSize, FileInfoClassToNT(FileInformationClass)));
}

DLLEXPORT_FUNC(void, GetSystemTimeAsFileTime, (LPFILETIME lpSystemTimeAsFileTime)) {
  LARGE_INTEGER Time;
  NtQuerySystemTime(&Time);
  lpSystemTimeAsFileTime->dwLowDateTime = Time.LowPart;
  lpSystemTimeAsFileTime->dwHighDateTime = Time.HighPart;
}

DLLEXPORT_FUNC(void, GetSystemTimePreciseAsFileTime, (LPFILETIME lpSystemTimeAsFileTime)) {
  GetSystemTimeAsFileTime(lpSystemTimeAsFileTime);
}

DLLEXPORT_FUNC(WINBOOL, SetCurrentDirectoryA, (LPCSTR lpPathName)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(WINBOOL, SetCurrentDirectoryW, (LPCWSTR lpPathName)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(DWORD, GetCurrentDirectoryA, (DWORD nBufferLength, LPSTR lpBuffer)) {
  UNIMPLEMENTED();
}

DLLEXPORT_FUNC(DWORD, GetCurrentDirectoryW, (DWORD nBufferLength, LPWSTR lpBuffer)) {
  return RtlGetCurrentDirectory_U(nBufferLength * sizeof(wchar_t), lpBuffer) / sizeof(wchar_t);
}
