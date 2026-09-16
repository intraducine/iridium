#pragma once
#include "callret_stub.h"
#include "CallRetStack.h"
#include <mutex>
using NTSTATUS = uint32_t;
constexpr NTSTATUS STATUS_NO_MEMORY = 0xc0000017;
static std::mutex ThreadCreationMutex;
static int initialized, finalized, created, destroyed;
namespace FEX::Windows {
inline void InitCRTThread(){++initialized;}
inline void DeinitCRTThread(){++finalized;}
}
struct TestParams { uintptr_t hStdError; };
using RTL_USER_PROCESS_PARAMETERS64 = TestParams;
struct TestPEB { TestParams *ProcessParameters=nullptr; };
struct TestTEB { TestPEB *ProcessEnvironmentBlock; };
static TestPEB peb;
static TestTEB teb{&peb};
static TestTEB *NtCurrentTeb(){ return &teb; }
static TestTEB *IOSLoadTEB(){ return &teb; }
static void IosTiLog(const char*){}
struct TestArea {
  static uint64_t limit,base;
  uint64_t &EmulatorStackLimit() const {return limit;}
  uint64_t &EmulatorStackBase() const {return base;}
};
uint64_t TestArea::limit{},TestArea::base{};
static TestArea GetCPUArea(){return {};}
struct TestContext {
  auto CreateThread(int,int){++created; return new FEXCore::Core::InternalThreadState;}
  void DestroyThread(FEXCore::Core::InternalThreadState *t){++destroyed;delete t;}
};
static TestContext context;
static TestContext *CTX=&context;
