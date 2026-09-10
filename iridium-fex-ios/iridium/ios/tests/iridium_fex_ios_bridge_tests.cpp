#include "../include/iridium_fex_ios_bridge.h"
#include "../src/iridium_fex_ios_jit_runtime_internal.h"

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
#include "../include/iridium_fex_ios_guest_loader.h"
#include "../include/iridium_fex_ios_elf_compat.h"
#include "../include/iridium_fex_ios_syscall_bridge.h"
#include "../src/iridium_fex_ios_guest_thread_state_internal.h"
#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Debug/InternalThreadState.h>
#endif

#include <array>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <limits.h>
#include <pthread.h>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <thread>
#include <time.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace {

int fail(const std::string& message) {
  std::cerr << message << '\n';
  return 1;
}

void require(bool condition, const std::string& message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}

struct ScopedEnvironmentOverride {
  explicit ScopedEnvironmentOverride(const char* key, const char* value)
    : key(key) {
    if (const char* existing = std::getenv(key); existing != nullptr) {
      hadPrevious = true;
      previousValue = existing;
    }
    setenv(key, value, 1);
  }

  ~ScopedEnvironmentOverride() {
    if (hadPrevious) {
      setenv(key.c_str(), previousValue.c_str(), 1);
    } else {
      unsetenv(key.c_str());
    }
  }

  std::string key;
  bool hadPrevious {false};
  std::string previousValue;
};

fs::path make_temp_dir() {
  std::string root = "/tmp";
  if (const char* temp_root = std::getenv("TMPDIR"); temp_root != nullptr && temp_root[0] != '\0') {
    root = temp_root;
  }
  if (!root.empty() && root.back() == '/') {
    root.pop_back();
  }

  std::string template_path = root + "/iridium-fex-test-XXXXXX";
  std::vector<char> buffer(template_path.begin(), template_path.end());
  buffer.push_back('\0');
  char* created_path = ::mkdtemp(buffer.data());
  require(created_path != nullptr, "failed to create temporary test directory");
  return fs::path(created_path);
}

void write_file(const fs::path& path, const std::string& value) {
  fs::create_directories(path.parent_path());
  std::ofstream stream(path);
  stream << value;
}

void write_binary_file(const fs::path& path, const std::vector<uint8_t>& value) {
  fs::create_directories(path.parent_path());
  std::ofstream stream(path, std::ios::binary);
  stream.write(reinterpret_cast<const char*>(value.data()), static_cast<std::streamsize>(value.size()));
}

std::string read_text_file(const fs::path& path) {
  std::ifstream stream(path);
  return std::string(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
}

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
fs::path write_minimal_loaderless_pie_binary(const fs::path& root) {
  const auto binary = root / "guest-pie.bin";
  constexpr uint64_t header_segment_size = 0x100;
  constexpr uint64_t code_offset = 0x1000;
  constexpr uint64_t code_vaddr = 0x1000;
  constexpr uint64_t code_size = 1;

  std::vector<uint8_t> image(static_cast<size_t>(code_offset + code_size), 0);

  Elf64_Ehdr ehdr {};
  ehdr.e_ident[EI_MAG0] = ELFMAG0;
  ehdr.e_ident[EI_MAG1] = ELFMAG1;
  ehdr.e_ident[EI_MAG2] = ELFMAG2;
  ehdr.e_ident[EI_MAG3] = ELFMAG3;
  ehdr.e_ident[EI_CLASS] = ELFCLASS64;
  ehdr.e_ident[EI_DATA] = ELFDATA2LSB;
  ehdr.e_ident[6] = 1;
  ehdr.e_type = ET_DYN;
  ehdr.e_machine = EM_X86_64;
  ehdr.e_version = 1;
  ehdr.e_entry = code_vaddr;
  ehdr.e_phoff = sizeof(Elf64_Ehdr);
  ehdr.e_ehsize = sizeof(Elf64_Ehdr);
  ehdr.e_phentsize = sizeof(Elf64_Phdr);
  ehdr.e_phnum = 2;

  std::array<Elf64_Phdr, 2> phdrs {};
  phdrs[0].p_type = PT_LOAD;
  phdrs[0].p_flags = PF_R;
  phdrs[0].p_offset = 0;
  phdrs[0].p_vaddr = 0;
  phdrs[0].p_filesz = header_segment_size;
  phdrs[0].p_memsz = header_segment_size;
  phdrs[0].p_align = 0x1000;

  phdrs[1].p_type = PT_LOAD;
  phdrs[1].p_flags = PF_R | PF_X;
  phdrs[1].p_offset = code_offset;
  phdrs[1].p_vaddr = code_vaddr;
  phdrs[1].p_filesz = code_size;
  phdrs[1].p_memsz = code_size;
  phdrs[1].p_align = 0x1000;

  std::memcpy(image.data(), &ehdr, sizeof(ehdr));
  std::memcpy(image.data() + ehdr.e_phoff, phdrs.data(), sizeof(phdrs));
  image[static_cast<size_t>(code_offset)] = 0xC3;

  write_binary_file(binary, image);
  return binary;
}

fs::path write_loaderless_pie_with_tls_relocations(const fs::path& root) {
  const auto binary = root / "guest-pie-tls.bin";
  constexpr uint64_t header_segment_size = 0x100;
  constexpr uint64_t rw_offset = 0x1000;
  constexpr uint64_t rw_vaddr = 0x2000;
  constexpr uint64_t rw_size = 0x400;
  constexpr uint64_t tls_vaddr = 0x2400;
  constexpr uint64_t dtpmod_target = 0x2200;
  constexpr uint64_t dtpoff_target = 0x2208;
  constexpr uint64_t tpoff_target = 0x2210;
  constexpr uint64_t dyn_vaddr = rw_vaddr;
  constexpr uint64_t rela_vaddr = 0x2080;
  constexpr uint64_t symtab_vaddr = 0x20e0;
  constexpr uint64_t strtab_vaddr = 0x2140;

  std::vector<uint8_t> image(static_cast<size_t>(rw_offset + rw_size), 0);

  Elf64_Ehdr ehdr {};
  ehdr.e_ident[EI_MAG0] = ELFMAG0;
  ehdr.e_ident[EI_MAG1] = ELFMAG1;
  ehdr.e_ident[EI_MAG2] = ELFMAG2;
  ehdr.e_ident[EI_MAG3] = ELFMAG3;
  ehdr.e_ident[EI_CLASS] = ELFCLASS64;
  ehdr.e_ident[EI_DATA] = ELFDATA2LSB;
  ehdr.e_ident[6] = 1;
  ehdr.e_type = ET_DYN;
  ehdr.e_machine = EM_X86_64;
  ehdr.e_version = 1;
  ehdr.e_entry = 0;
  ehdr.e_phoff = sizeof(Elf64_Ehdr);
  ehdr.e_ehsize = sizeof(Elf64_Ehdr);
  ehdr.e_phentsize = sizeof(Elf64_Phdr);
  ehdr.e_phnum = 4;

  std::array<Elf64_Phdr, 4> phdrs {};
  phdrs[0].p_type = PT_LOAD;
  phdrs[0].p_flags = PF_R;
  phdrs[0].p_offset = 0;
  phdrs[0].p_vaddr = 0;
  phdrs[0].p_filesz = header_segment_size;
  phdrs[0].p_memsz = header_segment_size;
  phdrs[0].p_align = 0x1000;

  phdrs[1].p_type = PT_LOAD;
  phdrs[1].p_flags = PF_R | PF_W;
  phdrs[1].p_offset = rw_offset;
  phdrs[1].p_vaddr = rw_vaddr;
  phdrs[1].p_filesz = rw_size;
  phdrs[1].p_memsz = rw_size;
  phdrs[1].p_align = 0x1000;

  phdrs[2].p_type = PT_DYNAMIC;
  phdrs[2].p_flags = PF_R | PF_W;
  phdrs[2].p_offset = rw_offset;
  phdrs[2].p_vaddr = dyn_vaddr;
  phdrs[2].p_filesz = 8 * sizeof(Elf64_Dyn);
  phdrs[2].p_memsz = 8 * sizeof(Elf64_Dyn);
  phdrs[2].p_align = 8;

  phdrs[3].p_type = PT_TLS;
  phdrs[3].p_flags = PF_R;
  phdrs[3].p_offset = rw_offset + 0x300;
  phdrs[3].p_vaddr = tls_vaddr;
  phdrs[3].p_paddr = tls_vaddr;
  phdrs[3].p_filesz = 0x20;
  phdrs[3].p_memsz = 0x40;
  phdrs[3].p_align = 8;

  std::array<Elf64_Dyn, 8> dyn {};
  dyn[0].d_tag = DT_RELA;
  dyn[0].d_un.d_ptr = rela_vaddr;
  dyn[1].d_tag = DT_RELASZ;
  dyn[1].d_un.d_val = 3 * sizeof(Elf64_Rela);
  dyn[2].d_tag = DT_RELAENT;
  dyn[2].d_un.d_val = sizeof(Elf64_Rela);
  dyn[3].d_tag = DT_SYMTAB;
  dyn[3].d_un.d_ptr = symtab_vaddr;
  dyn[4].d_tag = DT_SYMENT;
  dyn[4].d_un.d_val = sizeof(Elf64_Sym);
  dyn[5].d_tag = DT_STRTAB;
  dyn[5].d_un.d_ptr = strtab_vaddr;
  dyn[6].d_tag = DT_STRSZ;
  dyn[6].d_un.d_val = 12;
  dyn[7].d_tag = DT_NULL;
  std::memcpy(image.data() + rw_offset, dyn.data(), sizeof(dyn));

  std::array<Elf64_Rela, 3> rela {};
  rela[0].r_offset = dtpmod_target;
  rela[0].r_info = (1ULL << 32) | R_X86_64_DTPMOD64;
  rela[0].r_addend = 0;
  rela[1].r_offset = dtpoff_target;
  rela[1].r_info = (1ULL << 32) | R_X86_64_DTPOFF64;
  rela[1].r_addend = 0x18;
  rela[2].r_offset = tpoff_target;
  rela[2].r_info = R_X86_64_TPOFF64;
  rela[2].r_addend = 0x28;
  std::memcpy(image.data() + rw_offset + (rela_vaddr - rw_vaddr), rela.data(), sizeof(rela));

  std::array<Elf64_Sym, 2> symbols {};
  symbols[1].st_name = 1;
  symbols[1].st_info = 0;
  symbols[1].st_shndx = 1;
  symbols[1].st_value = 0x30;
  std::memcpy(image.data() + rw_offset + (symtab_vaddr - rw_vaddr), symbols.data(), sizeof(symbols));

  const char strtab[] = "\0tls_symbol";
  std::memcpy(image.data() + rw_offset + (strtab_vaddr - rw_vaddr), strtab, sizeof(strtab));
  std::memcpy(image.data(), &ehdr, sizeof(ehdr));
  std::memcpy(image.data() + ehdr.e_phoff, phdrs.data(), sizeof(phdrs));

  write_binary_file(binary, image);
  return binary;
}

fs::path write_loaderless_pie_with_unresolved_plt_relocation(const fs::path& root) {
  const auto binary = root / "guest-pie-plt.bin";
  constexpr uint64_t header_segment_size = 0x100;
  constexpr uint64_t rw_offset = 0x1000;
  constexpr uint64_t rw_vaddr = 0x2000;
  constexpr uint64_t rw_size = 0x400;
  constexpr uint64_t dyn_vaddr = rw_vaddr;
  constexpr uint64_t jmprel_vaddr = 0x2080;
  constexpr uint64_t symtab_vaddr = 0x20c0;
  constexpr uint64_t strtab_vaddr = 0x2120;
  constexpr uint64_t jump_slot_target = 0x2200;

  std::vector<uint8_t> image(static_cast<size_t>(rw_offset + rw_size), 0);

  Elf64_Ehdr ehdr {};
  ehdr.e_ident[EI_MAG0] = ELFMAG0;
  ehdr.e_ident[EI_MAG1] = ELFMAG1;
  ehdr.e_ident[EI_MAG2] = ELFMAG2;
  ehdr.e_ident[EI_MAG3] = ELFMAG3;
  ehdr.e_ident[EI_CLASS] = ELFCLASS64;
  ehdr.e_ident[EI_DATA] = ELFDATA2LSB;
  ehdr.e_ident[6] = 1;
  ehdr.e_type = ET_DYN;
  ehdr.e_machine = EM_X86_64;
  ehdr.e_version = 1;
  ehdr.e_entry = 0;
  ehdr.e_phoff = sizeof(Elf64_Ehdr);
  ehdr.e_ehsize = sizeof(Elf64_Ehdr);
  ehdr.e_phentsize = sizeof(Elf64_Phdr);
  ehdr.e_phnum = 3;

  std::array<Elf64_Phdr, 3> phdrs {};
  phdrs[0].p_type = PT_LOAD;
  phdrs[0].p_flags = PF_R;
  phdrs[0].p_offset = 0;
  phdrs[0].p_vaddr = 0;
  phdrs[0].p_filesz = header_segment_size;
  phdrs[0].p_memsz = header_segment_size;
  phdrs[0].p_align = 0x1000;

  phdrs[1].p_type = PT_LOAD;
  phdrs[1].p_flags = PF_R | PF_W;
  phdrs[1].p_offset = rw_offset;
  phdrs[1].p_vaddr = rw_vaddr;
  phdrs[1].p_filesz = rw_size;
  phdrs[1].p_memsz = rw_size;
  phdrs[1].p_align = 0x1000;

  phdrs[2].p_type = PT_DYNAMIC;
  phdrs[2].p_flags = PF_R | PF_W;
  phdrs[2].p_offset = rw_offset;
  phdrs[2].p_vaddr = dyn_vaddr;
  phdrs[2].p_filesz = 10 * sizeof(Elf64_Dyn);
  phdrs[2].p_memsz = 10 * sizeof(Elf64_Dyn);
  phdrs[2].p_align = 8;

  std::array<Elf64_Dyn, 10> dyn {};
  dyn[0].d_tag = DT_JMPREL;
  dyn[0].d_un.d_ptr = jmprel_vaddr;
  dyn[1].d_tag = DT_PLTRELSZ;
  dyn[1].d_un.d_val = sizeof(Elf64_Rela);
  dyn[2].d_tag = DT_PLTREL;
  dyn[2].d_un.d_val = DT_RELA;
  dyn[3].d_tag = DT_SYMTAB;
  dyn[3].d_un.d_ptr = symtab_vaddr;
  dyn[4].d_tag = DT_SYMENT;
  dyn[4].d_un.d_val = sizeof(Elf64_Sym);
  dyn[5].d_tag = DT_STRTAB;
  dyn[5].d_un.d_ptr = strtab_vaddr;
  dyn[6].d_tag = DT_STRSZ;
  dyn[6].d_un.d_val = 16;
  dyn[7].d_tag = DT_NULL;
  std::memcpy(image.data() + rw_offset, dyn.data(), sizeof(dyn));

  Elf64_Rela jmprel {};
  jmprel.r_offset = jump_slot_target;
  jmprel.r_info = (1ULL << 32) | R_X86_64_JUMP_SLOT;
  jmprel.r_addend = 0;
  std::memcpy(image.data() + rw_offset + (jmprel_vaddr - rw_vaddr), &jmprel, sizeof(jmprel));

  std::array<Elf64_Sym, 2> symbols {};
  symbols[1].st_name = 1;
  symbols[1].st_info = 0x12;
  symbols[1].st_shndx = SHN_UNDEF;
  symbols[1].st_value = 0;
  std::memcpy(image.data() + rw_offset + (symtab_vaddr - rw_vaddr), symbols.data(), sizeof(symbols));

  const char strtab[] = "\0wine_import";
  std::memcpy(image.data() + rw_offset + (strtab_vaddr - rw_vaddr), strtab, sizeof(strtab));
  std::memcpy(image.data(), &ehdr, sizeof(ehdr));
  std::memcpy(image.data() + ehdr.e_phoff, phdrs.data(), sizeof(phdrs));

  write_binary_file(binary, image);
  return binary;
}

void test_guest_loader_avoids_overwriting_the_fixed_stack_slot() {
  const auto root = make_temp_dir();
  const auto guest_binary = write_minimal_loaderless_pie_binary(root);

  constexpr uint64_t guest_stack_size = 8ULL * 1024ULL * 1024ULL;

  void* preferred_stack_reservation = mmap(
    nullptr,
    guest_stack_size,
    PROT_READ | PROT_WRITE,
    MAP_PRIVATE | MAP_ANONYMOUS,
    -1,
    0
  );
  require(
    preferred_stack_reservation != MAP_FAILED && preferred_stack_reservation != nullptr,
    "test should be able to reserve the preferred guest stack slot"
  );

  const uint64_t preferred_guest_stack_base = reinterpret_cast<uint64_t>(preferred_stack_reservation);
  const uint64_t preferred_guest_stack_top = preferred_guest_stack_base + guest_stack_size;
  char preferred_stack_top_text[32] = {};
  std::snprintf(
    preferred_stack_top_text,
    sizeof(preferred_stack_top_text),
    "0x%llx",
    static_cast<unsigned long long>(preferred_guest_stack_top)
  );
  ScopedEnvironmentOverride preferredStackHint(
    "IRIDIUM_FEX_IOS_TEST_GUEST_STACK_HINT_TOP",
    preferred_stack_top_text
  );

  std::memset(preferred_stack_reservation, 0xA5, 64);

  const auto result = iridium::fex::ios::guest::GuestBinaryLoader::LoadAndInitializeGuest(
    guest_binary.string(),
    reinterpret_cast<FEXCore::Context::Context*>(1),
    {guest_binary.string()},
    {"WINEARCH=win64"}
  );

  require(result.success, "guest loader should fall back to a different guest stack slot: " + result.error_message);
  require(result.stack_address != 0, "guest loader should return a guest stack pointer");
  require(
    result.stack_address < preferred_guest_stack_base || result.stack_address >= preferred_guest_stack_top,
    "guest loader should not place the stack inside the occupied preferred slot"
  );

  const auto* sentinel = reinterpret_cast<const uint8_t*>(preferred_stack_reservation);
  for (size_t index = 0; index < 64; ++index) {
    require(sentinel[index] == 0xA5, "guest loader should not overwrite the occupied preferred stack slot");
  }

  require(
    munmap(preferred_stack_reservation, guest_stack_size) == 0,
    "test should clean up the reserved preferred guest stack slot"
  );
  require(
    munmap(reinterpret_cast<void*>(result.load_base), result.mapped_size) == 0,
    "guest loader test should clean up its mapped ELF image"
  );
}
#endif

void write_valid_userland_root_at(const fs::path& root) {
  const auto launcher = root / "bin" / "wine64";
  write_file(
    launcher,
    "#!/bin/zsh\n"
    "sleep 0.05\n"
    "exit 0\n"
  );
  fs::permissions(
    launcher,
    fs::perms::owner_read | fs::perms::owner_write | fs::perms::owner_exec |
      fs::perms::group_read | fs::perms::group_exec |
      fs::perms::others_read | fs::perms::others_exec,
    fs::perm_options::add
  );
}

void make_executable(const fs::path& path) {
  fs::permissions(
    path,
    fs::perms::owner_read | fs::perms::owner_write | fs::perms::owner_exec |
      fs::perms::group_read | fs::perms::group_exec |
      fs::perms::others_read | fs::perms::others_exec,
    fs::perm_options::add
  );
}

void write_valid_userland_root(const fs::path& bundle_root) {
  write_valid_userland_root_at(bundle_root / "Support" / "wine-userland");
}

IridiumFEXIOSLaunchPaths make_launch_paths(
  const fs::path& translator,
  const fs::path& executable,
  const fs::path& bundle_root,
  const fs::path& prefix_root,
  const fs::path& environment
) {
  return IridiumFEXIOSLaunchPaths {
    translator.c_str(),
    executable.c_str(),
    bundle_root.c_str(),
    prefix_root.c_str(),
    environment.c_str(),
    "direct",
    "win64",
    nullptr,
    0,
  };
}

void test_probe_readiness_requires_explicit_ready() {
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  write_file(translator, "translator");

  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness(translator.c_str(), "", &readiness) == 0,
    "probe_readiness should succeed"
  );
  require(readiness.translator_present == 1, "translator should be detected");
  require(readiness.jit_required == 1, "embedded bridge should always require explicit JIT readiness");
  require(readiness.jit_ready == 0, "empty jit status should not be treated as ready");
  require(readiness.launch_ready == 0, "launch_ready should fail closed");
  require(std::string(readiness.launch_status) == "jitRequired", "launch status should expose JIT gating");
  require(std::string(readiness.jit_session_kind) == "none", "missing debugger state should report no trusted session kind");
  require(std::string(readiness.jit_tool_recommendation) == "stikdebug", "missing debugger state should recommend StikDebug by default");
  require(
    std::string(readiness.status_summary) == "No external debugger/JIT session detected.",
    "probe_readiness should surface the missing debugger signal"
  );
}

void test_probe_readiness_reports_launch_ready_once_jit_is_ready() {
  ScopedEnvironmentOverride smokeExecution("IRIDIUM_FEX_IOS_SMOKE_EXECUTION", "1");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  write_file(translator, "translator");

  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness(translator.c_str(), "ready", &readiness) == IRIDIUM_FEX_IOS_STATUS_OK,
    "probe_readiness should succeed"
  );
  require(readiness.translator_present == 1, "translator should be detected");
  require(readiness.jit_ready == 1, "ready jit state should be detected");
  require(readiness.launch_ready == 1, "launch readiness should report a real execution path");
  require(std::string(readiness.launch_status) == "bootstrapReady", "launch status should expose bootstrap readiness without claiming playability");
  require(
    std::string(readiness.status_summary) ==
      "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified.",
    "bootstrap summary should name the unverified runtime milestones"
  );
  require(std::string(readiness.allocator_backend) == "none", "host tests should report the generic backend");
  require(std::string(readiness.jit_session_kind) == "debugger-backed", "ready host launches should default to debugger-backed session tracking");
}

void test_probe_readiness_reports_runtime_jit_unavailable() {
  ScopedEnvironmentOverride forcedUnavailable("IRIDIUM_FEX_IOS_FORCE_JIT_UNAVAILABLE", "1");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  write_file(translator, "translator");

  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness(translator.c_str(), "ready", &readiness) == IRIDIUM_FEX_IOS_STATUS_OK,
    "probe_readiness should succeed even when runtime JIT probing fails"
  );
  require(readiness.translator_present == 1, "translator should still be detected");
  require(readiness.jit_ready == 0, "runtime JIT probe failure should clear jit_ready");
  require(readiness.launch_ready == 0, "launch should fail closed when runtime JIT probing fails");
  require(std::string(readiness.jit_status) == "unavailable", "jit status should expose runtime unavailability");
  require(std::string(readiness.launch_status) == "jitUnavailable", "launch status should expose runtime JIT unavailability");
  require(std::string(readiness.jit_failure_stage) == "forced unavailable for testing", "runtime probe failures should surface the explicit failure stage");
  require(
    std::string(readiness.status_summary).find("forced unavailable for testing") != std::string::npos,
    "runtime probe failures should surface the forced-unavailable detail"
  );
}

void test_allocator_probe_can_force_outcomes() {
  {
    ScopedEnvironmentOverride forcedRequired("IRIDIUM_FEX_IOS_TEST_READINESS", "required");
    IridiumFEXIOSAllocatorProbe probe {};
    require(
      iridium_fex_ios_probe_allocator("ready", &probe) == IRIDIUM_FEX_IOS_STATUS_OK,
      "allocator probe should decode forced required state"
    );
    require(std::string(probe.status) == "required", "forced required should win");
    require(std::string(probe.failure_stage) == "debugger signal missing", "required should expose the missing-signal stage");
  }

  {
    ScopedEnvironmentOverride forcedUnavailable("IRIDIUM_FEX_IOS_TEST_READINESS", "unavailable");
    IridiumFEXIOSAllocatorProbe probe {};
    require(
      iridium_fex_ios_probe_allocator("ready", &probe) == IRIDIUM_FEX_IOS_STATUS_OK,
      "allocator probe should decode forced unavailable state"
    );
    require(std::string(probe.status) == "unavailable", "forced unavailable should win");
    require(std::string(probe.failure_stage) == "debug-map registration failed", "forced unavailable should use the default stage");
  }

  {
    ScopedEnvironmentOverride forcedReady("IRIDIUM_FEX_IOS_TEST_READINESS", "ready");
    IridiumFEXIOSAllocatorProbe probe {};
    require(
      iridium_fex_ios_probe_allocator("", &probe) == IRIDIUM_FEX_IOS_STATUS_OK,
      "allocator probe should decode forced ready state"
    );
    require(std::string(probe.status) == "ready", "forced ready should win");
    require(probe.execution_succeeded == 1, "forced ready should mark execution as successful");
  }
}

void test_allocator_probe_exercises_real_host_split_allocator_when_enabled() {
  ScopedEnvironmentOverride enableSplitAllocatorOnHost("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST", "1");
  IridiumFEXIOSAllocatorProbe probe {};
  require(
    iridium_fex_ios_probe_allocator("ready", &probe) == IRIDIUM_FEX_IOS_STATUS_OK,
    "allocator probe should exercise the real host split allocator"
  );
  require(std::string(probe.status) == "ready", "real host allocator probe should succeed");
  require(std::string(probe.backend) == "split-rx-rw-debugger", "real host allocator probe should report the split backend");
  require(probe.allocation_succeeded == 1, "real host allocator probe should allocate executable code memory");
  require(probe.write_succeeded == 1, "real host allocator probe should write through the writable alias");
  require(probe.execution_succeeded == 1, "real host allocator probe should execute through the RX view");
  require(std::string(probe.status_summary) == "JIT allocator ready.", "real host allocator probe should report allocator readiness only");
}

void test_probe_readiness_reports_real_host_split_allocator_when_enabled() {
  ScopedEnvironmentOverride enableSplitAllocatorOnHost("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST", "1");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  write_file(translator, "translator");

  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness(translator.c_str(), "ready", &readiness) == IRIDIUM_FEX_IOS_STATUS_OK,
    "probe_readiness should succeed with the real host split allocator"
  );
  require(readiness.jit_ready == 1, "real host split allocator should keep JIT ready");
  require(readiness.launch_ready == 1, "real host split allocator should mark launch ready once the minimal syscall bridge is wired");
  require(std::string(readiness.allocator_backend) == "split-rx-rw-debugger", "probe_readiness should surface the split backend");
  require(std::string(readiness.jit_session_kind) == "debugger-backed", "split allocator readiness should report a debugger-backed session");
  require(std::string(readiness.launch_status) == "bootstrapReady", "probe_readiness should surface bootstrap readiness");
  require(
    std::string(readiness.status_summary) ==
      "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified.",
    "probe_readiness should not report full runtime readiness before runtime milestones pass"
  );
}

void test_allocator_probe_fails_closed_under_xcode_debug_environment() {
  ScopedEnvironmentOverride enableSplitAllocatorOnHost("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST", "1");
  ScopedEnvironmentOverride xcodeDebug("__XCODE_BUILT_PRODUCTS_DIR_PATHS", "/tmp/xcode-products");
  IridiumFEXIOSAllocatorProbe probe {};
  require(
    iridium_fex_ios_probe_allocator("ready", &probe) == IRIDIUM_FEX_IOS_STATUS_OK,
    "allocator probe should decode Xcode-debugger interception as unavailable"
  );
  require(std::string(probe.status) == "unavailable", "Xcode debugger should fail closed instead of claiming runtime readiness");
  require(std::string(probe.backend) == "xcode-debugger-check", "Xcode debugger path should expose the lightweight-check backend marker");
  require(std::string(probe.failure_stage) == "execution probe skipped under xcode debugger", "Xcode debugger path should expose the skipped execution stage");
  require(
    std::string(probe.status_summary) ==
      "Xcode is attached; Iridium will skip the unsafe execute probe but still requires the real runtime backend to pass under a non-Xcode debugger-backed session.",
    "Xcode debugger path should explain why runtime launch stays blocked"
  );
}

void test_probe_readiness_fails_closed_under_xcode_debug_environment() {
  ScopedEnvironmentOverride enableSplitAllocatorOnHost("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST", "1");
  ScopedEnvironmentOverride xcodeDebug("__XCODE_BUILT_PRODUCTS_DIR_PATHS", "/tmp/xcode-products");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  write_file(translator, "translator");

  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness(translator.c_str(), "ready", &readiness) == IRIDIUM_FEX_IOS_STATUS_OK,
    "probe_readiness should succeed for the blocked Xcode-debugger case"
  );
  require(readiness.jit_ready == 0, "Xcode debugger path should not report jit ready");
  require(readiness.launch_ready == 0, "Xcode debugger path should fail launch closed");
  require(std::string(readiness.launch_status) == "jitUnavailable", "Xcode debugger path should surface runtime unavailability");
  require(std::string(readiness.allocator_backend) == "xcode-debugger-check", "probe_readiness should surface the lightweight-check backend marker");
  require(
    std::string(readiness.status_summary) ==
      "Xcode is attached; Iridium will skip the unsafe execute probe but still requires the real runtime backend to pass under a non-Xcode debugger-backed session.",
    "probe_readiness should explain why Xcode-attached launch stays blocked"
  );
}

void test_allocator_probe_honors_explicit_execution_probe_skip_request() {
  ScopedEnvironmentOverride enableSplitAllocatorOnHost("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST", "1");
  ScopedEnvironmentOverride skipExecutionProbe("IRIDIUM_FEX_IOS_SKIP_EXECUTION_PROBE", "1");
  IridiumFEXIOSAllocatorProbe probe {};
  require(
    iridium_fex_ios_probe_allocator("ready", &probe) == IRIDIUM_FEX_IOS_STATUS_OK,
    "allocator probe should honor an explicit execution-probe skip request"
  );
  require(std::string(probe.status) == "ready", "explicit execution-probe skip should preserve readiness");
  require(std::string(probe.backend) == "split-rx-rw-debugger", "explicit execution-probe skip should report the allocator it actually exercised");
  require(probe.allocation_succeeded == 1, "explicit execution-probe skip should still allocate executable code memory");
  require(probe.write_succeeded == 1, "explicit execution-probe skip should still verify the writable code alias");
  require(probe.execution_succeeded == 0, "explicit execution-probe skip should not claim generated code was executed");
  require(std::string(probe.failure_stage) == "execution probe skipped for debugger-backed session", "explicit execution-probe skip should surface the non-Xcode skipped execution stage");
  require(std::string(probe.status_summary) == "JIT allocator ready.", "explicit execution-probe skip should only claim allocator readiness");
}

void test_probe_readiness_reports_trollstore_private_session_kind() {
  ScopedEnvironmentOverride forcedReady("IRIDIUM_FEX_IOS_TEST_READINESS", "ready");
  ScopedEnvironmentOverride sessionKind("IRIDIUM_FEX_IOS_JIT_SESSION_KIND", "trollstore-private");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  write_file(translator, "translator");

  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness(translator.c_str(), "ready", &readiness) == IRIDIUM_FEX_IOS_STATUS_OK,
    "probe_readiness should succeed for trollstore-private sessions"
  );
  require(std::string(readiness.jit_session_kind) == "trollstore-private", "probe_readiness should surface the trollstore-private session kind");
}

void test_txm_capability_matches_current_stikdebug_device_policy() {
  require(
    !iridium::ios::infer_stikdebug_txm_capability(26, "iPhone14,1"),
    "iOS 26 iPhone14,1 should remain on the non-TXM path"
  );
  require(
    iridium::ios::infer_stikdebug_txm_capability(26, "iPhone14,2"),
    "iOS 26 iPhone14,2 should use the TXM callback path"
  );
  require(
    !iridium::ios::infer_stikdebug_txm_capability(26, "iPad14,4"),
    "iOS 26 iPad14,4 should remain on the non-TXM path"
  );
  require(
    iridium::ios::infer_stikdebug_txm_capability(26, "iPad14,5"),
    "iOS 26 iPad14,5 should use the TXM callback path"
  );
  require(
    !iridium::ios::infer_stikdebug_txm_capability(26, "iPad14,11"),
    "iOS 26 multi-digit model suffixes must match StikDebug's decimal-version policy"
  );
  require(
    !iridium::ios::infer_stikdebug_txm_capability(27, "iPad8,11"),
    "iOS 27 A12Z iPad Pro should remain on the non-TXM path"
  );
  require(
    iridium::ios::infer_stikdebug_txm_capability(27, "iPhone12,1"),
    "iOS 27 A13 devices should use the TXM callback path"
  );
  require(
    !iridium::ios::infer_stikdebug_txm_capability(25, "iPhone17,1"),
    "pre-iOS 26 devices should not use the TXM callback path"
  );
}

void test_probe_readiness_reports_bootstrap_required_metadata() {
  ScopedEnvironmentOverride forcedReady("IRIDIUM_FEX_IOS_TEST_READINESS", "ready");
  ScopedEnvironmentOverride debuggerSession("IRIDIUM_FEX_IOS_JIT_SESSION_KIND", "debugger-backed");
  ScopedEnvironmentOverride bootstrapRequired("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_REQUIRED", "1");
  ScopedEnvironmentOverride bootstrapKind("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_KIND", "stikdebug-script");
  ScopedEnvironmentOverride bootstrapSummary(
    "IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_SUMMARY",
    "StikDebug still needs to complete the executable region bootstrap script."
  );
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  write_file(translator, "translator");

  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness(translator.c_str(), "ready", &readiness) == IRIDIUM_FEX_IOS_STATUS_OK,
    "probe_readiness should succeed for bootstrap-required metadata"
  );
  require(readiness.jit_ready == 0, "bootstrap-required state should not report jit ready");
  require(readiness.launch_ready == 0, "bootstrap-required state should fail launch closed");
  require(std::string(readiness.jit_status) == "unavailable", "bootstrap-required state should map to unavailable");
  require(std::string(readiness.launch_status) == "jitBootstrapRequired", "bootstrap-required state should surface a dedicated launch status");
  require(readiness.tool_bootstrap_required == 1, "bootstrap-required state should set the bootstrap flag");
  require(std::string(readiness.jit_tool_recommendation) == "stikdebug", "bootstrap-required state should surface the tool recommendation");
  require(std::string(readiness.tool_bootstrap_kind) == "stikdebug-script", "bootstrap-required state should surface the bootstrap kind");
  require(
    std::string(readiness.tool_bootstrap_summary) == "StikDebug still needs to complete the executable region bootstrap script.",
    "bootstrap-required state should surface the bootstrap summary"
  );
}

void test_probe_readiness_requires_helper_bootstrap_before_host_fallback_ready() {
  ScopedEnvironmentOverride bootstrapRequired("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_REQUIRED", "1");
  ScopedEnvironmentOverride bootstrapKind("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_KIND", "stikdebug-script");
  ScopedEnvironmentOverride bootstrapSummary(
    "IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_SUMMARY",
    "Debugger attach is present, but StikDebug still needs to complete the required executable region bootstrap script."
  );
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  write_file(translator, "translator");

  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness(translator.c_str(), "ready", &readiness) == IRIDIUM_FEX_IOS_STATUS_OK,
    "probe_readiness should succeed while reporting a helper-bootstrap blocker"
  );
  require(readiness.jit_ready == 0, "helper-bootstrap-required state should not fall through to host fallback readiness");
  require(readiness.launch_ready == 0, "helper-bootstrap-required state should fail launch closed before helper completion");
  require(std::string(readiness.jit_status) == "unavailable", "helper-bootstrap-required state should map to unavailable");
  require(std::string(readiness.launch_status) == "jitBootstrapRequired", "helper-bootstrap-required state should surface a dedicated launch status");
  require(readiness.tool_bootstrap_required == 1, "helper-bootstrap-required state should set the bootstrap flag");
  require(
    std::string(readiness.status_summary) ==
      "Debugger-backed helper bootstrap is not available on this host build.",
    "host fallback should surface the concrete missing helper-bootstrap implementation"
  );
}

void test_helper_bootstrap_command_dispatch_on_host_simulation() {
  ScopedEnvironmentOverride simulatedBootstrap("IRIDIUM_FEX_IOS_SIMULATE_HELPER_BOOTSTRAP", "1");
  iridium::ios::reset_jit_bootstrap_test_state();

  const auto installExtension = iridium::ios::install_jit_bootstrap_extension_script("globalThis.__iridiumExtensionLoaded = true;");
  require(installExtension.handled, "bootstrap simulation should accept extension installation");
  require(installExtension.value == 1, "bootstrap simulation should acknowledge extension installation");
  require(iridium::ios::jit_bootstrap_test_extension_loaded(), "bootstrap simulation should record extension installation");

  const auto detachPolicy = iridium::ios::configure_jit_bootstrap_detach_after_first_breakpoint(true);
  require(detachPolicy.handled, "bootstrap simulation should accept detach policy updates");
  require(iridium::ios::jit_bootstrap_test_detach_after_first_breakpoint(), "bootstrap simulation should track detach policy");

  const auto preparedRegion = iridium::ios::prepare_jit_bootstrap_executable_region(16384);
  require(preparedRegion.handled, "bootstrap simulation should prepare an executable region");
  require(preparedRegion.value != 0, "bootstrap simulation should return a prepared region pointer");

  auto* region = reinterpret_cast<unsigned char*>(preparedRegion.value);
  region[0] = 0x44;
  region[1] = 0x99;
  const auto patchPrepared = iridium::ios::prepare_jit_bootstrap_patch_region(region, 2);
  require(patchPrepared.handled, "bootstrap simulation should round-trip a patch region");
  require(region[0] == 0x44 && region[1] == 0x99, "bootstrap simulation should preserve the patch bytes");

  const auto detached = iridium::ios::detach_jit_bootstrap_session();
  require(detached.handled, "bootstrap simulation should support detach");
  require(iridium::ios::jit_bootstrap_test_detached(), "bootstrap simulation should record detach");
}

void test_probe_readiness_can_complete_stikdebug_helper_bootstrap() {
  ScopedEnvironmentOverride enableSplitAllocatorOnHost("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST", "1");
  ScopedEnvironmentOverride skipExecutionProbe("IRIDIUM_FEX_IOS_SKIP_EXECUTION_PROBE", "1");
  ScopedEnvironmentOverride simulatedBootstrap("IRIDIUM_FEX_IOS_SIMULATE_HELPER_BOOTSTRAP", "1");
  ScopedEnvironmentOverride bootstrapRequired("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_REQUIRED", "1");
  ScopedEnvironmentOverride bootstrapKind("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_KIND", "stikdebug-script");
  ScopedEnvironmentOverride bootstrapSummary(
    "IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_SUMMARY",
    "Debugger attach is present, but StikDebug still needs to complete the required executable region bootstrap script."
  );
  ScopedEnvironmentOverride debuggerSession("IRIDIUM_FEX_IOS_JIT_SESSION_KIND", "debugger-backed");
  iridium::ios::reset_jit_bootstrap_test_state();

  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  write_file(translator, "translator");

  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness(translator.c_str(), "ready", &readiness) == IRIDIUM_FEX_IOS_STATUS_OK,
    "probe_readiness should succeed after helper bootstrap simulation"
  );
  require(readiness.jit_ready == 1, "helper bootstrap simulation should make jit ready");
  require(readiness.launch_ready == 1, "helper bootstrap simulation should make launch ready once the minimal syscall bridge is wired");
  require(std::string(readiness.jit_status) == "ready", "helper bootstrap simulation should surface ready status");
  require(std::string(readiness.launch_status) == "bootstrapReady", "helper bootstrap simulation should surface bootstrap readiness");
  require(std::string(readiness.allocator_backend) == "split-rx-rw-debugger", "helper bootstrap simulation should keep the debugger-backed allocator");
  require(iridium::ios::jit_bootstrap_test_extension_loaded(), "helper bootstrap simulation should install the extension script");
}

void test_probe_readiness_requires_translator_artifact() {
  IridiumFEXIOSReadiness readiness {};
  require(
    iridium_fex_ios_probe_readiness("/tmp/does-not-exist", "ready", &readiness) == IRIDIUM_FEX_IOS_STATUS_OK,
    "probe_readiness should still decode missing translator state"
  );
  require(readiness.translator_present == 0, "missing translator should be reported");
  require(readiness.launch_ready == 0, "launch must fail closed without a translator");
  require(std::string(readiness.launch_status) == "translatorMissing", "launch status should expose missing translator");
}

void test_validate_launch_checks_environment_contract() {
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(environment, "WINEPREFIX=/wrong\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n");

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);

  char error[256] = {};
  require(
    iridium_fex_ios_validate_launch(&paths, error, sizeof(error)) == IRIDIUM_FEX_IOS_STATUS_WINEPREFIX_MISMATCH,
    "validate_launch should reject mismatched WINEPREFIX"
  );
  require(std::string(error) == "environment file does not bind the expected WINEPREFIX", "error message should be decodable");
}

void test_validate_launch_reports_specific_missing_executable_status() {
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "missing-game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);

  char error[256] = {};
  require(
    iridium_fex_ios_validate_launch(&paths, error, sizeof(error)) == IRIDIUM_FEX_IOS_STATUS_EXECUTABLE_MISSING,
    "validate_launch should report the specific missing executable status"
  );
  require(std::string(error) == "selected executable is missing", "missing executable error should remain user-facing");
}

void test_validate_launch_reports_specific_missing_prefix_status() {
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "missing-prefix";
  const auto environment_parent = root / "env";
  const auto environment = environment_parent / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(environment_parent);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);

  char error[256] = {};
  require(
    iridium_fex_ios_validate_launch(&paths, error, sizeof(error)) == IRIDIUM_FEX_IOS_STATUS_PREFIX_ROOT_MISSING,
    "validate_launch should report the specific missing prefix-root status"
  );
  require(std::string(error) == "prefix root is missing", "missing prefix error should remain user-facing");
}

void test_validate_launch_rejects_non_direct_mode() {
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  IridiumFEXIOSLaunchPaths paths {
    translator.c_str(),
    executable.c_str(),
    bundle_root.c_str(),
    prefix_root.c_str(),
    environment.c_str(),
    "shell",
    "win64",
    nullptr,
    0,
  };

  char error[256] = {};
  require(
    iridium_fex_ios_validate_launch(&paths, error, sizeof(error)) == IRIDIUM_FEX_IOS_STATUS_DIRECT_LAUNCH_REQUIRED,
    "validate_launch should reject non-direct launch requests"
  );
}

void test_validate_launch_rejects_non_win64_guest() {
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  IridiumFEXIOSLaunchPaths paths {
    translator.c_str(),
    executable.c_str(),
    bundle_root.c_str(),
    prefix_root.c_str(),
    environment.c_str(),
    "direct",
    "win32",
    nullptr,
    0,
  };

  char error[256] = {};
  require(
    iridium_fex_ios_validate_launch(&paths, error, sizeof(error)) == IRIDIUM_FEX_IOS_STATUS_GUEST_ARCHITECTURE_UNSUPPORTED,
    "validate_launch should reject non-win64 launches"
  );
}

void test_validate_launch_accepts_explicit_userland_root_override() {
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";
  const auto override_root = root / "support-root";

  write_file(translator, "translator");
  write_file(executable, "exe");
  fs::create_directories(bundle_root);
  fs::create_directories(prefix_root);
  write_valid_userland_root_at(override_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\n"
      "IRIDIUM_NO_DESKTOP=1\n"
      "IRIDIUM_USERLAND_ROOT=" + override_root.string() + "\n"
      "WINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);
  char error[256] = {};
  require(
    iridium_fex_ios_validate_launch(&paths, error, sizeof(error)) == IRIDIUM_FEX_IOS_STATUS_OK,
    "validate_launch should accept an explicit userland root override"
  );
}

void test_validate_launch_rejects_wine_preloader_without_companion_wine_binary() {
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto userland_root = bundle_root / "Support" / "wine-userland";
  const auto wine_root = userland_root / "lib" / "wine" / "x86_64-unix";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_file(wine_root / "wine-preloader", "preloader");
  make_executable(wine_root / "wine-preloader");
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);

  char error[256] = {};
  require(
    iridium_fex_ios_validate_launch(&paths, error, sizeof(error)) == IRIDIUM_FEX_IOS_STATUS_RUNTIME_CONTRACT_INVALID,
    "validate_launch should reject wine-preloader without the Unix Wine loader companion"
  );
  require(
    std::string(error) == "wine-preloader requires a companion Unix Wine loader",
    "missing preloader companion error should remain user-facing"
  );
}

void test_start_guest_execution_rejects_non_ready_jit() {
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);
  char session[256] = {};
  char error[256] = {};
  require(
    iridium_fex_ios_start_guest_execution(&paths, "pending", session, sizeof(session), error, sizeof(error)) ==
      IRIDIUM_FEX_IOS_STATUS_JIT_NOT_READY,
    "start_guest_execution should fail when JIT is not ready"
  );
  require(
    std::string(error) == "No external debugger/JIT session detected.",
    "start_guest_execution should surface the missing debugger signal"
  );
}

void test_start_guest_execution_rejects_runtime_jit_probe_failure() {
  ScopedEnvironmentOverride forcedUnavailable("IRIDIUM_FEX_IOS_FORCE_JIT_UNAVAILABLE", "1");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);
  char session[256] = {};
  char error[256] = {};
  require(
    iridium_fex_ios_start_guest_execution(&paths, "ready", session, sizeof(session), error, sizeof(error)) ==
      IRIDIUM_FEX_IOS_STATUS_JIT_NOT_READY,
    "start_guest_execution should fail when runtime JIT probing fails"
  );
  require(
    std::string(error).find("forced unavailable for testing") != std::string::npos,
    "start_guest_execution should surface runtime JIT probe failures"
  );
}

void test_start_guest_execution_rejects_xcode_debug_launches() {
  ScopedEnvironmentOverride enableSplitAllocatorOnHost("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST", "1");
  ScopedEnvironmentOverride xcodeDebug("__XCODE_BUILT_PRODUCTS_DIR_PATHS", "/tmp/xcode-products");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);
  char session[256] = {};
  char error[256] = {};
  require(
    iridium_fex_ios_start_guest_execution(&paths, "ready", session, sizeof(session), error, sizeof(error)) ==
      IRIDIUM_FEX_IOS_STATUS_JIT_NOT_READY,
    "start_guest_execution should fail closed under Xcode-attached debugger launches"
  );
  require(
    std::string(error) ==
      "Xcode is attached; Iridium will skip the unsafe execute probe but still requires the real runtime backend to pass under a non-Xcode debugger-backed session.",
    "start_guest_execution should surface the Xcode lightweight-check explanation"
  );
}

void test_session_lifecycle_collects_real_terminal_result() {
  ScopedEnvironmentOverride bootstrapOverride("IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY", "1");
  ScopedEnvironmentOverride smokeExecution("IRIDIUM_FEX_IOS_SMOKE_EXECUTION", "1");
  ScopedEnvironmentOverride smokeGuestImage("IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE", "1");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);

  char session[256] = {};
  char error[256] = {};
  require(
    iridium_fex_ios_start_guest_execution(&paths, "ready", session, sizeof(session), error, sizeof(error)) ==
      IRIDIUM_FEX_IOS_STATUS_OK,
    "start_guest_execution should accept valid inputs"
  );
  require(std::string(session).find("embedded-fex-session-") == 0, "session id should be unique");

  IridiumFEXIOSExecutionPoll poll {};
  require(
    iridium_fex_ios_poll_guest_state(session, &poll) == IRIDIUM_FEX_IOS_STATUS_OK,
    "poll_guest_state should succeed"
  );
  require(std::string(poll.state) == "accepted", "first poll should be deterministic");
  require(std::string(poll.status_summary).find("accepted") != std::string::npos, "first poll summary should be decodable");

  require(
    iridium_fex_ios_poll_guest_state(session, &poll) == IRIDIUM_FEX_IOS_STATUS_OK,
    "second poll_guest_state should succeed"
  );
  require(
    std::string(poll.state) == "running" || std::string(poll.state) == "completed",
    "intermediate state should stay decodable"
  );

  require(
    iridium_fex_ios_poll_guest_state(session, &poll) == IRIDIUM_FEX_IOS_STATUS_OK,
    "terminal poll_guest_state should succeed"
  );
  require(
    std::string(poll.state) == "running" || std::string(poll.state) == "completed",
    "terminal poll should expose running or completed state"
  );

  IridiumFEXIOSExecutionResult result {};
  require(
    iridium_fex_ios_collect_guest_exit(session, "completed", &result) == IRIDIUM_FEX_IOS_STATUS_OK,
    "collect_guest_exit should succeed"
  );
  require(result.succeeded == 1, "bridge should collect a successful terminal result");
  require(std::string(result.terminal_state) == "completed", "terminal state should be completed");
  require(result.failure_code == nullptr, "success should not report a failure code");
  require(result.failure_reason == nullptr, "success should not report a failure reason");
}

void test_session_lifecycle_does_not_report_running_before_guest_execution() {
  ScopedEnvironmentOverride bootstrapOverride("IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY", "1");
  ScopedEnvironmentOverride smokeGuestImage("IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE", "1");
  ScopedEnvironmentOverride initializationHold("IRIDIUM_FEX_IOS_TEST_INITIALIZATION_HOLD_MS", "200");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);

  char session[256] = {};
  char error[256] = {};
  require(
    iridium_fex_ios_start_guest_execution(&paths, "ready", session, sizeof(session), error, sizeof(error)) ==
      IRIDIUM_FEX_IOS_STATUS_OK,
    "start_guest_execution should accept valid inputs for lifecycle handoff gating"
  );

  bool saw_initializing = false;
  bool saw_premature_running = false;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (!saw_initializing && std::chrono::steady_clock::now() < deadline) {
    IridiumFEXIOSExecutionPoll poll {};
    require(
      iridium_fex_ios_poll_guest_state(session, &poll) == IRIDIUM_FEX_IOS_STATUS_OK,
      "poll_guest_state should succeed while guest initialization is held"
    );
    const std::string state = poll.state ? poll.state : "";
    const std::string summary = poll.status_summary ? poll.status_summary : "";
    if (state == "initializing") {
      saw_initializing = true;
    }
    if (state == "running" && summary.find("mapped and running") != std::string::npos) {
      saw_premature_running = true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  require(saw_initializing, "polling should expose the initializing state while FEX has not entered guest execution");
  require(!saw_premature_running, "polling must not report running before Wine guest execution starts");

  IridiumFEXIOSExecutionResult result {};
  require(
    iridium_fex_ios_collect_guest_exit(session, "completed", &result) == IRIDIUM_FEX_IOS_STATUS_OK,
    "collect_guest_exit should clean up after lifecycle handoff gating test"
  );
}

void test_session_lifecycle_accepts_runtime_session_stop_request() {
  ScopedEnvironmentOverride bootstrapOverride("IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY", "1");
  ScopedEnvironmentOverride smokeExecution("IRIDIUM_FEX_IOS_SMOKE_EXECUTION", "1");
  ScopedEnvironmentOverride smokeGuestImage("IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE", "1");
  ScopedEnvironmentOverride startupDelay("IRIDIUM_FEX_IOS_TEST_GUEST_THREAD_STARTUP_DELAY_MS", "50");
  ScopedEnvironmentOverride runtimeSession("IRIDIUM_RUNTIME_SESSION_ID", "runtime-player-session");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);

  char session[256] = {};
  char error[256] = {};
  require(
    iridium_fex_ios_start_guest_execution(&paths, "ready", session, sizeof(session), error, sizeof(error)) ==
      IRIDIUM_FEX_IOS_STATUS_OK,
    "start_guest_execution should accept valid inputs with a runtime session id"
  );
  require(std::string(session) == "runtime-player-session", "bridge should use the runtime session id when provided");

  char stop_error[256] = {};
  require(
    iridium_fex_ios_request_guest_stop(session, stop_error, sizeof(stop_error)) == IRIDIUM_FEX_IOS_STATUS_OK,
    "request_guest_stop should accept the active runtime session id"
  );

  IridiumFEXIOSExecutionResult result {};
  require(
    iridium_fex_ios_collect_guest_exit(session, "completed", &result) == IRIDIUM_FEX_IOS_STATUS_OK,
    "collect_guest_exit should succeed after a stop request"
  );
  require(result.succeeded == 0, "stopped runtime player sessions should not collect as successful game exits");
  require(std::string(result.terminal_state) == "failed", "stopped runtime player session should collect as failed");
  require(result.failure_reason != nullptr, "stopped runtime player session should report a failure reason");
  require(
    std::string(result.failure_reason).find("stop request") != std::string::npos,
    "stopped runtime player session should explain that the fullscreen player requested the stop"
  );
}

void test_collect_guest_exit_waits_for_guest_thread_startup() {
  ScopedEnvironmentOverride bootstrapOverride("IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY", "1");
  ScopedEnvironmentOverride smokeExecution("IRIDIUM_FEX_IOS_SMOKE_EXECUTION", "1");
  ScopedEnvironmentOverride smokeGuestImage("IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE", "1");
  ScopedEnvironmentOverride startupDelay("IRIDIUM_FEX_IOS_TEST_GUEST_THREAD_STARTUP_DELAY_MS", "50");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() + "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\n"
  );

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);

  char session[256] = {};
  char error[256] = {};
  require(
    iridium_fex_ios_start_guest_execution(&paths, "ready", session, sizeof(session), error, sizeof(error)) ==
      IRIDIUM_FEX_IOS_STATUS_OK,
    "start_guest_execution should accept valid inputs for the startup-delay regression test"
  );

  IridiumFEXIOSExecutionResult result {};
  require(
    iridium_fex_ios_collect_guest_exit(session, "completed", &result) == IRIDIUM_FEX_IOS_STATUS_OK,
    "collect_guest_exit should wait for the delayed guest thread"
  );
  require(result.succeeded == 1, "bridge should still collect a successful terminal result after delayed startup");
  require(std::string(result.terminal_state) == "completed", "terminal state should be completed after delayed startup");
  require(result.failure_code == nullptr, "delayed startup success should not report a failure code");
  require(result.failure_reason == nullptr, "delayed startup success should not report a failure reason");
}

void test_guest_thread_captures_launch_environment_before_async_startup() {
  ScopedEnvironmentOverride bootstrapOverride("IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY", "1");
  ScopedEnvironmentOverride smokeGuestImage("IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE", "1");
  ScopedEnvironmentOverride startupDelay("IRIDIUM_FEX_IOS_TEST_GUEST_THREAD_STARTUP_DELAY_MS", "50");
  ScopedEnvironmentOverride stderrStress("IRIDIUM_FEX_IOS_TEST_WRITE_STDERR_BYTES", "300000");
  ScopedEnvironmentOverride runtimeSession("IRIDIUM_RUNTIME_SESSION_ID", "runtime-player-session-env");
  const auto root = make_temp_dir();
  const auto translator = root / "translator.bin";
  const auto executable = root / "game.exe";
  const auto bundle_root = root / "bundle";
  const auto prefix_root = root / "prefix";
  const auto environment = root / "prefix" / "runtime.env";
  const auto captured_environment = root / "captured-guest-env.txt";
  const auto wine_debug_log = root / "wine-debug.log";
  const auto framebuffer = root / "framebuffer.bgra";
  const auto input_events = root / "input.csv";
  const auto audio_state = root / "audio.json";

  write_file(translator, "translator");
  write_file(executable, "exe");
  write_valid_userland_root(bundle_root);
  fs::create_directories(prefix_root);
  write_file(
    environment,
    "WINEPREFIX=" + prefix_root.string() +
      "\nIRIDIUM_NO_DESKTOP=1\nWINEARCH=win64\nIRIDIUM_WINE_USER_SHARED_DATA_ADDRESS=0x17ffe0000\nWINEDEBUGLOG=" + wine_debug_log.string() +
      "\nIRIDIUM_FEX_IOS_TEST_CAPTURE_LAUNCH_ENV_PATH=" + captured_environment.string() + "\n"
  );

  setenv("IRIDIUM_WINE_IOS_SURFACE_ID", "surface.runtime-player-session-env", 1);
  setenv("IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH", framebuffer.c_str(), 1);
  setenv("IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH", input_events.c_str(), 1);
  setenv("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH", audio_state.c_str(), 1);
  setenv("IRIDIUM_WINE_IOS_SURFACE_WIDTH", "4", 1);
  setenv("IRIDIUM_WINE_IOS_SURFACE_HEIGHT", "2", 1);

  const auto paths = make_launch_paths(translator, executable, bundle_root, prefix_root, environment);

  char session[256] = {};
  char error[256] = {};
  require(
    iridium_fex_ios_start_guest_execution(&paths, "ready", session, sizeof(session), error, sizeof(error)) ==
      IRIDIUM_FEX_IOS_STATUS_OK,
    "start_guest_execution should accept valid inputs for async environment capture"
  );

  unsetenv("IRIDIUM_WINE_IOS_SURFACE_ID");
  unsetenv("IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH");
  unsetenv("IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH");
  unsetenv("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH");
  unsetenv("IRIDIUM_WINE_IOS_SURFACE_WIDTH");
  unsetenv("IRIDIUM_WINE_IOS_SURFACE_HEIGHT");

  IridiumFEXIOSExecutionResult result {};
  require(
    iridium_fex_ios_collect_guest_exit(session, "completed", &result) == IRIDIUM_FEX_IOS_STATUS_OK,
    "collect_guest_exit should succeed after async environment capture"
  );
  require(fs::exists(captured_environment), "guest thread should capture its launch environment");
  const auto contents = read_text_file(captured_environment);
  require(
    contents.find("IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH=" + framebuffer.string() + "\n") != std::string::npos,
    "guest launch environment should retain the framebuffer bridge path captured at start"
  );
  require(
    contents.find("IRIDIUM_WINE_IOS_SURFACE_WIDTH=4\n") != std::string::npos,
    "guest launch environment should retain the surface width captured at start"
  );
  require(
    contents.find("WINEDEBUGLOG=" + wine_debug_log.string() + "\n") != std::string::npos,
    "guest launch environment should retain the Wine debug log path"
  );
#if defined(__APPLE__)
  require(
    contents.find("IRIDIUM_WINE_USER_SHARED_DATA_ADDRESS=0x7000000000\n") != std::string::npos,
    "Darwin guest launch environment should normalize stale shared-data overrides to Wine's fixed high address"
  );
#endif
  require(fs::exists(wine_debug_log), "guest launch should create the Wine debug log file");
  require(
    read_text_file(wine_debug_log).find("iridium-fex-ios: wine stderr capture active") != std::string::npos,
    "guest launch should redirect stderr into the Wine debug log file"
  );
  require(
    read_text_file(wine_debug_log).find("wine stderr capture truncated after 262144 bytes") != std::string::npos,
    "guest launch should cap excessive stderr writes"
  );
  require(
    fs::file_size(wine_debug_log) < 270000,
    "guest launch should keep Wine debug log capture bounded"
  );
}

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
void test_guest_loader_maps_loaderless_pie_without_fixed_low_base() {
  ScopedEnvironmentOverride skipStackSetup("IRIDIUM_FEX_IOS_TEST_SKIP_GUEST_STACK_SETUP", "1");
  const auto root = make_temp_dir();
  const auto guest_binary = write_minimal_loaderless_pie_binary(root);

  const auto result = iridium::fex::ios::guest::GuestBinaryLoader::LoadAndInitializeGuest(
    guest_binary.string(),
    reinterpret_cast<FEXCore::Context::Context*>(1),
    {guest_binary.string()},
    {"WINEARCH=win64"}
  );

  require(result.success, "guest loader should accept a minimal loaderless PIE: " + result.error_message);
  require(result.load_base != 0x0000000000400000ULL, "guest loader should not pin ET_DYN binaries at 0x400000");
  require(result.entrypoint != 0, "guest loader should resolve an entrypoint for ET_DYN payloads");
  require(result.phdr_address != 0, "guest loader should resolve AT_PHDR for ET_DYN payloads");
  require(result.phdr_count == 2, "guest loader should preserve the program header count");

  require(
    munmap(reinterpret_cast<void*>(result.load_base), result.mapped_size) == 0,
    "guest loader test should clean up its mapped ELF image"
  );
}

void test_guest_loader_stack_includes_at_random_auxv() {
  const auto root = make_temp_dir();
  const auto guest_binary = write_minimal_loaderless_pie_binary(root);

  const auto result = iridium::fex::ios::guest::GuestBinaryLoader::LoadAndInitializeGuest(
    guest_binary.string(),
    reinterpret_cast<FEXCore::Context::Context*>(1),
    {guest_binary.string()},
    {"WINEARCH=win64"}
  );

  require(result.success, "guest loader should build a guest stack for auxv inspection: " + result.error_message);

  const auto* cursor = reinterpret_cast<const uint64_t*>(result.stack_address);
  const uint64_t argc = *cursor++;
  for (uint64_t index = 0; index < argc; ++index) {
    require(*cursor++ != 0, "guest stack argv entries should be populated before auxv");
  }
  require(*cursor++ == 0, "guest stack argv should be null terminated");
  while (*cursor != 0) {
    ++cursor;
  }
  ++cursor;

  uint64_t random_seed_address = 0;
  for (;;) {
    const uint64_t key = *cursor++;
    const uint64_t value = *cursor++;
    if (key == AT_NULL) {
      break;
    }
    if (key == AT_RANDOM) {
      random_seed_address = value;
    }
  }

  require(random_seed_address != 0, "guest stack auxv should include AT_RANDOM for glibc guard initialization");
  const auto* random_seed = reinterpret_cast<const uint8_t*>(random_seed_address);
  const std::array<uint8_t, 16> expected_seed = {{
    0x69, 0x72, 0x69, 0x64, 0x69, 0x75, 0x6d, 0x2d,
    0x66, 0x65, 0x78, 0x2d, 0x61, 0x75, 0x78, 0x76,
  }};
  require(
    std::memcmp(random_seed, expected_seed.data(), expected_seed.size()) == 0,
    "guest stack AT_RANDOM should point at the seeded 16-byte guard buffer"
  );

  require(
    munmap(reinterpret_cast<void*>(result.load_base), result.mapped_size) == 0,
    "guest loader AT_RANDOM test should clean up its mapped ELF image"
  );
}

void test_guest_loader_applies_x86_64_tls_relocations() {
  ScopedEnvironmentOverride skipStackSetup("IRIDIUM_FEX_IOS_TEST_SKIP_GUEST_STACK_SETUP", "1");
  const auto root = make_temp_dir();
  const auto guest_binary = write_loaderless_pie_with_tls_relocations(root);

  const auto result = iridium::fex::ios::guest::GuestBinaryLoader::LoadAndInitializeGuest(
    guest_binary.string(),
    reinterpret_cast<FEXCore::Context::Context*>(1),
    {guest_binary.string()},
    {"WINEARCH=win64"}
  );

  require(result.success, "guest loader should apply x86_64 TLS relocations: " + result.error_message);
  const auto* mapped = reinterpret_cast<const uint8_t*>(result.load_base);
  const uint64_t load_bias = result.load_base;
  const auto relocated_value = [&](uint64_t guest_vaddr) {
    return *reinterpret_cast<const uint64_t*>(mapped + load_bias + guest_vaddr - result.load_base);
  };

  require(relocated_value(0x2200) == 0, "DTPMOD64 should resolve to the main module identifier placeholder");
  require(relocated_value(0x2208) == 0x48, "DTPOFF64 should resolve to the TLS symbol offset plus addend");
  require(relocated_value(0x2210) == 0x2428, "TPOFF64 without a symbol should resolve from the PT_TLS base plus addend");

  require(
    munmap(reinterpret_cast<void*>(result.load_base), result.mapped_size) == 0,
    "guest loader test should clean up its mapped ELF image"
  );
}

void test_guest_loader_patches_unresolved_plt_imports_to_trap_stub() {
  ScopedEnvironmentOverride skipStackSetup("IRIDIUM_FEX_IOS_TEST_SKIP_GUEST_STACK_SETUP", "1");
  const auto root = make_temp_dir();
  const auto guest_binary = write_loaderless_pie_with_unresolved_plt_relocation(root);

  const auto result = iridium::fex::ios::guest::GuestBinaryLoader::LoadAndInitializeGuest(
    guest_binary.string(),
    reinterpret_cast<FEXCore::Context::Context*>(1),
    {guest_binary.string()},
    {"WINEARCH=win64"}
  );

  require(result.success, "guest loader should keep unresolved PLT imports loadable: " + result.error_message);
  const uint64_t relocated_target = *reinterpret_cast<const uint64_t*>(result.load_base + 0x2200);
  require(relocated_target != 0, "unresolved PLT import should point at a trap stub instead of null");
  const auto* trap = reinterpret_cast<const uint8_t*>(relocated_target);
  require(trap[0] == 0x0f && trap[1] == 0x0b, "trap stub should begin with x86_64 UD2");

  require(
    munmap(reinterpret_cast<void*>(result.load_base), result.mapped_size) == 0,
    "guest loader test should clean up its mapped ELF image"
  );
}

void test_minimal_darwin_syscall_handler_supports_basic_memory_and_write_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_map_private = 0x02;
  constexpr uint64_t linux_map_anonymous = 0x20;
  constexpr uint64_t linux_map_stack = 0x20000;

  FEXCore::HLE::SyscallArguments mmap_args {};
  mmap_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::mmap);
  mmap_args.Argument[1] = 0;
  mmap_args.Argument[2] = 4096;
  mmap_args.Argument[3] = PROT_READ | PROT_WRITE;
  mmap_args.Argument[4] = linux_map_private | linux_map_anonymous;
  mmap_args.Argument[5] = static_cast<uint64_t>(-1);
  mmap_args.Argument[6] = 0;
  const uint64_t mapped = handler->HandleSyscall(nullptr, &mmap_args);
  require(static_cast<int64_t>(mapped) > 0, "minimal Darwin syscall handler should mmap anonymous memory");

  auto* mapped_bytes = reinterpret_cast<char*>(mapped);
  mapped_bytes[0] = 'o';
  mapped_bytes[1] = 'k';

  FEXCore::HLE::SyscallArguments stack_mmap_args = mmap_args;
  stack_mmap_args.Argument[4] = linux_map_private | linux_map_anonymous | linux_map_stack;
  const uint64_t mapped_stack = handler->HandleSyscall(nullptr, &stack_mmap_args);
  require(static_cast<int64_t>(mapped_stack) > 0, "minimal Darwin syscall handler should accept Linux MAP_STACK");
  require(munmap(reinterpret_cast<void*>(mapped_stack), 4096) == 0, "test should clean up MAP_STACK mapping");

  int pipe_fds[2] = {-1, -1};
  require(pipe(pipe_fds) == 0, "test should create a pipe for write syscall verification");

  FEXCore::HLE::SyscallArguments write_args {};
  write_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::write);
  write_args.Argument[1] = static_cast<uint64_t>(pipe_fds[1]);
  write_args.Argument[2] = mapped;
  write_args.Argument[3] = 2;
  require(handler->HandleSyscall(nullptr, &write_args) == 2, "minimal Darwin syscall handler should write guest memory bytes");

  char pipe_buffer[2] = {};
  require(read(pipe_fds[0], pipe_buffer, sizeof(pipe_buffer)) == 2, "test should read back syscall-written bytes");
  require(std::string(pipe_buffer, sizeof(pipe_buffer)) == "ok", "write syscall should preserve guest bytes");
  close(pipe_fds[0]);
  close(pipe_fds[1]);

  FEXCore::HLE::SyscallArguments mprotect_args {};
  mprotect_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::mprotect);
  mprotect_args.Argument[1] = mapped;
  mprotect_args.Argument[2] = 4096;
  mprotect_args.Argument[3] = PROT_READ;
  require(handler->HandleSyscall(nullptr, &mprotect_args) == 0, "minimal Darwin syscall handler should mprotect mapped memory");

  FEXCore::HLE::SyscallArguments munmap_args {};
  munmap_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::munmap);
  munmap_args.Argument[1] = mapped;
  munmap_args.Argument[2] = 4096;
  require(handler->HandleSyscall(nullptr, &munmap_args) == 0, "minimal Darwin syscall handler should munmap mapped memory");
}

void test_noreplace_preserves_existing_mapping() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  const auto size = static_cast<size_t>(sysconf(_SC_PAGESIZE));
  FEXCore::HLE::SyscallArguments args {};
  args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::mmap);
  args.Argument[2] = size;
  args.Argument[3] = PROT_READ | PROT_WRITE;
  args.Argument[4] = 0x02 | 0x20;
  args.Argument[5] = static_cast<uint64_t>(-1);
  const auto allocated = handler->HandleSyscall(nullptr, &args);
  require(static_cast<int64_t>(allocated) > 0, "allocate guest-owned no-replace test page");
  auto* existing = reinterpret_cast<unsigned char*>(allocated);
  existing[0] = 0xa5;
  args.Argument[1] = allocated;
  args.Argument[4] |= 0x100000;
  require(static_cast<int64_t>(handler->HandleSyscall(nullptr, &args)) == -17,
          "no-replace must return Linux EEXIST for an occupied page");
  require(existing[0] == 0xa5, "no-replace must preserve existing bytes");
  args.Argument[1] = uint64_t{1} << 63;
  require(static_cast<int64_t>(handler->HandleSyscall(nullptr, &args)) == -12,
          "an unsupported high address must return ENOMEM, not EEXIST");
  args.Argument[1] = allocated;
  args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::munmap);
  require(handler->HandleSyscall(nullptr, &args) == 0, "release no-replace test page");
}

void test_minimal_darwin_syscall_handler_zero_fills_private_file_mappings_past_eof() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  const auto temp_root = make_temp_dir();
  const auto file_path = temp_root / "partial-page.bin";
  const long page_size_value = ::sysconf(_SC_PAGESIZE);
  const auto page_size = page_size_value > 0 ? static_cast<size_t>(page_size_value) : static_cast<size_t>(0x1000);
  std::vector<uint8_t> file_data(page_size + 0x60, 0);
  file_data[page_size] = 0x41;
  write_binary_file(file_path, file_data);

  const int fd = ::open(file_path.c_str(), O_RDONLY);
  require(fd >= 0, "test should open the partial-page mapping fixture");

  const pid_t child = ::fork();
  require(child >= 0, "test should fork before touching a mapping that may SIGBUS");
  if (child == 0) {
    FEXCore::HLE::SyscallArguments mmap_args {};
    mmap_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::mmap);
    mmap_args.Argument[1] = 0;
    mmap_args.Argument[2] = page_size * 2;
    mmap_args.Argument[3] = PROT_READ | PROT_WRITE;
    mmap_args.Argument[4] = MAP_PRIVATE;
    mmap_args.Argument[5] = static_cast<uint64_t>(fd);
    mmap_args.Argument[6] = page_size;

    const auto mapped_result = handler->HandleSyscall(nullptr, &mmap_args);
    if (static_cast<int64_t>(mapped_result) < 0) {
      _exit(2);
    }

    auto* mapped = reinterpret_cast<uint8_t*>(mapped_result);
    if (mapped[0] != 0x41) {
      _exit(3);
    }
    mapped[page_size + 0x100] = 0x5a;
    if (mapped[page_size + 0x100] != 0x5a) {
      _exit(4);
    }
    ::munmap(mapped, page_size * 2);
    _exit(0);
  }

  int child_status = 0;
  require(::waitpid(child, &child_status, 0) == child, "test should collect the private file mapping child");
  ::close(fd);

  require(
    WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0,
    "private file mappings that extend past EOF should expose writable zero-filled pages instead of SIGBUS"
  );
}

void test_minimal_darwin_syscall_handler_accepts_guest_subpage_mprotect() {
  constexpr size_t guest_page_size = 0x1000;
  const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
  const auto host_page_size = host_page_size_value > 0
    ? static_cast<size_t>(host_page_size_value)
    : static_cast<size_t>(guest_page_size);
  if (host_page_size <= guest_page_size) {
    return;
  }

  void* host_page = ::mmap(
    nullptr,
    host_page_size,
    PROT_READ | PROT_WRITE,
    MAP_PRIVATE | MAP_ANON,
    -1,
    0
  );
  require(host_page != MAP_FAILED, "test should reserve a host page for guest subpage mprotect");

  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  FEXCore::HLE::SyscallArguments mprotect_args {};
  mprotect_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::mprotect);
  mprotect_args.Argument[1] = reinterpret_cast<uint64_t>(host_page) + guest_page_size;
  mprotect_args.Argument[2] = guest_page_size;
  mprotect_args.Argument[3] = PROT_READ;
  require(
    handler->HandleSyscall(nullptr, &mprotect_args) == 0,
    "minimal Darwin syscall handler should accept guest-page mprotect ranges inside a larger Darwin host page"
  );

  require(::munmap(host_page, host_page_size) == 0, "test should release the host page reservation");
}

void test_minimal_darwin_syscall_handler_zero_fills_fixed_anonymous_guest_subpages() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_map_private = 0x02;
  constexpr uint64_t linux_map_fixed = 0x10;
  constexpr uint64_t linux_map_anonymous = 0x20;
  constexpr size_t guest_page_size = 0x1000;

  const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
  const auto host_page_size = host_page_size_value > 0
    ? static_cast<size_t>(host_page_size_value)
    : static_cast<size_t>(guest_page_size);
  if (host_page_size <= guest_page_size) {
    return;
  }

  void* host_page = ::mmap(
    nullptr,
    host_page_size,
    PROT_READ | PROT_WRITE,
    MAP_PRIVATE | MAP_ANONYMOUS,
    -1,
    0
  );
  require(host_page != MAP_FAILED, "test should reserve a host page for fixed guest subpage mapping");
  iridium::fex::ios::SetGuestFixedMappingReservation(reinterpret_cast<uintptr_t>(host_page), host_page_size);

  auto* bytes = reinterpret_cast<uint8_t*>(host_page);
  std::memset(bytes, 0xA5, host_page_size);

  FEXCore::HLE::SyscallArguments mmap_args {};
  mmap_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::mmap);
  mmap_args.Argument[1] = reinterpret_cast<uint64_t>(bytes + guest_page_size);
  mmap_args.Argument[2] = guest_page_size;
  mmap_args.Argument[3] = PROT_READ | PROT_WRITE;
  mmap_args.Argument[4] = linux_map_private | linux_map_fixed | linux_map_anonymous;
  mmap_args.Argument[5] = static_cast<uint64_t>(-1);
  mmap_args.Argument[6] = 0;

  const auto mapped_result = handler->HandleSyscall(nullptr, &mmap_args);
  require(
    mapped_result == reinterpret_cast<uint64_t>(bytes + guest_page_size),
    "fixed anonymous guest subpage mmap should return the requested guest address"
  );

  for (size_t index = 0; index < guest_page_size; ++index) {
    require(bytes[index] == 0xA5, "fixed anonymous guest subpage mmap should preserve the preceding guest page");
  }
  for (size_t index = guest_page_size; index < guest_page_size * 2; ++index) {
    require(bytes[index] == 0, "fixed anonymous guest subpage mmap should zero-fill the requested guest page");
  }
  for (size_t index = guest_page_size * 2; index < host_page_size; ++index) {
    require(bytes[index] == 0xA5, "fixed anonymous guest subpage mmap should preserve the following guest pages");
  }

  iridium::fex::ios::ClearGuestFixedMappingReservation(reinterpret_cast<uintptr_t>(host_page), host_page_size);
  require(::munmap(host_page, host_page_size) == 0, "test should release the host page reservation");
}

void test_minimal_darwin_syscall_handler_maps_unreserved_fixed_anonymous_guest_subpages() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_map_private = 0x02;
  constexpr uint64_t linux_map_fixed = 0x10;
  constexpr uint64_t linux_map_anonymous = 0x20;
  constexpr uint64_t linux_map_fixed_noreplace = 0x100000;
  constexpr size_t guest_page_size = 0x1000;

  const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
  const auto host_page_size = host_page_size_value > 0
    ? static_cast<size_t>(host_page_size_value)
    : static_cast<size_t>(guest_page_size);
  if (host_page_size <= guest_page_size) {
    return;
  }

  void* host_page = ::mmap(
    nullptr,
    host_page_size,
    PROT_NONE,
    MAP_PRIVATE | MAP_ANONYMOUS,
    -1,
    0
  );
  require(host_page != MAP_FAILED, "test should reserve a host page address for unmapped fixed guest subpage mapping");
  require(::munmap(host_page, host_page_size) == 0, "test should release the host page before fixed guest mapping");

  auto* bytes = reinterpret_cast<uint8_t*>(host_page);
  FEXCore::HLE::SyscallArguments mmap_args {};
  mmap_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::mmap);
  mmap_args.Argument[1] = reinterpret_cast<uint64_t>(bytes + guest_page_size);
  mmap_args.Argument[2] = guest_page_size;
  mmap_args.Argument[3] = PROT_READ | PROT_WRITE;
  mmap_args.Argument[4] = linux_map_private | linux_map_fixed | linux_map_anonymous | linux_map_fixed_noreplace;
  mmap_args.Argument[5] = static_cast<uint64_t>(-1);
  mmap_args.Argument[6] = 0;

  const auto mapped_result = handler->HandleSyscall(nullptr, &mmap_args);
  require(
    mapped_result == reinterpret_cast<uint64_t>(bytes + guest_page_size),
    "fixed anonymous guest subpage mmap should allocate the enclosing unmapped host page"
  );

  bytes[guest_page_size] = 0x5A;
  require(bytes[guest_page_size] == 0x5A, "mapped guest subpage should be writable for runtime initialization");
  require(::munmap(host_page, host_page_size) == 0, "test should release the allocated fixed host page");
}

void test_minimal_darwin_syscall_handler_maps_guest_exec_file_subpages_without_host_exec() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_map_private = 0x02;
  constexpr uint64_t linux_map_fixed = 0x10;
  constexpr size_t guest_page_size = 0x1000;

  const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
  const auto host_page_size = host_page_size_value > 0
    ? static_cast<size_t>(host_page_size_value)
    : static_cast<size_t>(guest_page_size);
  if (host_page_size <= guest_page_size) {
    return;
  }

  const auto temp_root = make_temp_dir();
  const auto file_path = temp_root / "guest-text.bin";
  std::vector<uint8_t> file_data(guest_page_size * 2, 0);
  file_data[guest_page_size] = 0x4c;
  file_data[guest_page_size + 1] = 0x8b;
  write_binary_file(file_path, file_data);

  const int fd = ::open(file_path.c_str(), O_RDONLY);
  require(fd >= 0, "test should open the executable guest mapping fixture");

  void* host_page = ::mmap(
    nullptr,
    host_page_size,
    PROT_READ | PROT_WRITE,
    MAP_PRIVATE | MAP_ANONYMOUS,
    -1,
    0
  );
  require(host_page != MAP_FAILED, "test should reserve a host page for fixed executable guest subpage mapping");

  auto* bytes = reinterpret_cast<uint8_t*>(host_page);
  std::memset(bytes, 0xA5, host_page_size);

  FEXCore::HLE::SyscallArguments mmap_args {};
  mmap_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::mmap);
  mmap_args.Argument[1] = reinterpret_cast<uint64_t>(bytes + guest_page_size);
  mmap_args.Argument[2] = guest_page_size;
  mmap_args.Argument[3] = PROT_READ | PROT_EXEC;
  mmap_args.Argument[4] = linux_map_private | linux_map_fixed;
  mmap_args.Argument[5] = static_cast<uint64_t>(fd);
  mmap_args.Argument[6] = guest_page_size;

  const auto mapped_result = handler->HandleSyscall(nullptr, &mmap_args);
  ::close(fd);
  require(
    mapped_result == reinterpret_cast<uint64_t>(bytes + guest_page_size),
    "fixed executable guest file subpage mmap should not require host executable permissions"
  );
  require(bytes[guest_page_size] == 0x4c, "fixed executable guest file subpage mmap should copy file bytes");
  require(bytes[guest_page_size + 1] == 0x8b, "fixed executable guest file subpage mmap should copy adjacent file bytes");
  require(bytes[0] == 0xA5, "fixed executable guest file subpage mmap should preserve neighboring guest pages");

  require(::munmap(host_page, host_page_size) == 0, "test should release the host page reservation");
}

void test_minimal_darwin_syscall_handler_maps_fixed_files_with_guest_aligned_offsets() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_map_private = 0x02;
  constexpr uint64_t linux_map_fixed = 0x10;
  constexpr size_t guest_page_size = 0x1000;

  const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
  const auto host_page_size = host_page_size_value > 0
    ? static_cast<size_t>(host_page_size_value)
    : static_cast<size_t>(guest_page_size);
  if (host_page_size <= guest_page_size) {
    return;
  }

  const auto temp_root = make_temp_dir();
  const auto file_path = temp_root / "guest-offset.bin";
  std::vector<uint8_t> file_data(host_page_size + guest_page_size, 0);
  file_data[guest_page_size] = 0x57;
  file_data[guest_page_size + host_page_size - 1] = 0x45;
  write_binary_file(file_path, file_data);

  const int fd = ::open(file_path.c_str(), O_RDONLY);
  require(fd >= 0, "test should open the guest-offset mapping fixture");

  void* host_page = ::mmap(
    nullptr,
    host_page_size,
    PROT_READ | PROT_WRITE,
    MAP_PRIVATE | MAP_ANONYMOUS,
    -1,
    0
  );
  require(host_page != MAP_FAILED, "test should reserve a host page for fixed guest-offset mapping");

  auto* bytes = reinterpret_cast<uint8_t*>(host_page);
  std::memset(bytes, 0xA5, host_page_size);

  FEXCore::HLE::SyscallArguments mmap_args {};
  mmap_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::mmap);
  mmap_args.Argument[1] = reinterpret_cast<uint64_t>(bytes);
  mmap_args.Argument[2] = host_page_size;
  mmap_args.Argument[3] = PROT_READ | PROT_WRITE;
  mmap_args.Argument[4] = linux_map_private | linux_map_fixed;
  mmap_args.Argument[5] = static_cast<uint64_t>(fd);
  mmap_args.Argument[6] = guest_page_size;

  const auto mapped_result = handler->HandleSyscall(nullptr, &mmap_args);
  ::close(fd);
  require(
    mapped_result == reinterpret_cast<uint64_t>(bytes),
    "fixed guest file mmap should accept guest-page-aligned offsets on larger Darwin host pages"
  );
  require(bytes[0] == 0x57, "fixed guest file mmap should copy from the guest-aligned file offset");
  require(bytes[host_page_size - 1] == 0x45, "fixed guest file mmap should copy the full requested segment");

  require(::munmap(host_page, host_page_size) == 0, "test should release the host page reservation");
}

void test_minimal_darwin_syscall_handler_supports_preloader_file_and_process_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  const auto root = make_temp_dir();
  const auto payload = root / "payload.bin";
  write_file(payload, "preloader");

  FEXCore::HLE::SyscallArguments open_args {};
  open_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::open);
  open_args.Argument[1] = reinterpret_cast<uint64_t>(payload.c_str());
  open_args.Argument[2] = O_RDONLY;
  const int64_t fd = static_cast<int64_t>(handler->HandleSyscall(nullptr, &open_args));
  require(fd >= 0, "minimal Darwin syscall handler should open preloader input files");

  char buffer[9] = {};
  FEXCore::HLE::SyscallArguments read_args {};
  read_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::read);
  read_args.Argument[1] = static_cast<uint64_t>(fd);
  read_args.Argument[2] = reinterpret_cast<uint64_t>(buffer);
  read_args.Argument[3] = sizeof(buffer);
  require(
    handler->HandleSyscall(nullptr, &read_args) == sizeof(buffer),
    "minimal Darwin syscall handler should read bytes from opened preloader files"
  );
  require(std::string(buffer, sizeof(buffer)) == "preloader", "read syscall should preserve file bytes");

  FEXCore::HLE::SyscallArguments close_args {};
  close_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::close);
  close_args.Argument[1] = static_cast<uint64_t>(fd);
  require(handler->HandleSyscall(nullptr, &close_args) == 0, "minimal Darwin syscall handler should close file descriptors");

  FEXCore::HLE::SyscallArguments uid_args {};
  uid_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::getuid);
  require(handler->HandleSyscall(nullptr, &uid_args) == getuid(), "getuid should mirror the host uid");

  FEXCore::HLE::SyscallArguments gid_args {};
  gid_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::getgid);
  require(handler->HandleSyscall(nullptr, &gid_args) == getgid(), "getgid should mirror the host gid");

  FEXCore::HLE::SyscallArguments euid_args {};
  euid_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::geteuid);
  require(handler->HandleSyscall(nullptr, &euid_args) == geteuid(), "geteuid should mirror the host effective uid");

  FEXCore::HLE::SyscallArguments egid_args {};
  egid_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::getegid);
  require(handler->HandleSyscall(nullptr, &egid_args) == getegid(), "getegid should mirror the host effective gid");

  FEXCore::HLE::SyscallArguments prctl_args {};
  prctl_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::prctl);
  prctl_args.Argument[1] = 15;
  prctl_args.Argument[2] = reinterpret_cast<uint64_t>("wine-preloader");
  require(
    handler->HandleSyscall(nullptr, &prctl_args) == 0,
    "PR_SET_NAME should be accepted as a harmless preloader process-name hint"
  );

  FEXCore::HLE::SyscallArguments prctl_set_vma_args {};
  prctl_set_vma_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::prctl);
  prctl_set_vma_args.Argument[1] = 0x53564d41;
  prctl_set_vma_args.Argument[2] = 0;
  prctl_set_vma_args.Argument[3] = reinterpret_cast<uint64_t>(buffer);
  prctl_set_vma_args.Argument[4] = 0x1000;
  prctl_set_vma_args.Argument[5] = reinterpret_cast<uint64_t>("glibc: loader mapping");
  require(
    handler->HandleSyscall(nullptr, &prctl_set_vma_args) == 0,
    "PR_SET_VMA should be accepted as a harmless anonymous-mapping name hint"
  );
}

void test_minimal_darwin_syscall_handler_supports_interpreter_file_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  const auto root = make_temp_dir();
  const auto payload = root / "ld-linux.so.2";
  write_file(payload, "interpreter");

  constexpr uint64_t linux_at_fdcwd = static_cast<uint64_t>(-100);
  constexpr uint64_t linux_o_rdonly = 0;
  constexpr uint64_t linux_o_cloexec = 0x80000;

  FEXCore::HLE::SyscallArguments access_args {};
  access_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::access);
  access_args.Argument[1] = reinterpret_cast<uint64_t>(payload.c_str());
  access_args.Argument[2] = R_OK;
  require(handler->HandleSyscall(nullptr, &access_args) == 0, "access should accept readable interpreter paths");

  FEXCore::HLE::SyscallArguments openat_args {};
  openat_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::openat);
  openat_args.Argument[1] = linux_at_fdcwd;
  openat_args.Argument[2] = reinterpret_cast<uint64_t>(payload.c_str());
  openat_args.Argument[3] = linux_o_rdonly | linux_o_cloexec;
  const int64_t fd = static_cast<int64_t>(handler->HandleSyscall(nullptr, &openat_args));
  require(fd >= 0, "openat should translate common Linux loader flags");

  char buffer[6] = {};
  FEXCore::HLE::SyscallArguments pread_args {};
  pread_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::pread64);
  pread_args.Argument[1] = static_cast<uint64_t>(fd);
  pread_args.Argument[2] = reinterpret_cast<uint64_t>(buffer);
  pread_args.Argument[3] = sizeof(buffer);
  pread_args.Argument[4] = 5;
  require(handler->HandleSyscall(nullptr, &pread_args) == sizeof(buffer), "pread64 should read from an explicit offset");
  require(std::string(buffer, sizeof(buffer)) == "preter", "pread64 should preserve offset reads");

  FEXCore::HLE::SyscallArguments lseek_args {};
  lseek_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::lseek);
  lseek_args.Argument[1] = static_cast<uint64_t>(fd);
  lseek_args.Argument[2] = 0;
  lseek_args.Argument[3] = SEEK_SET;
  require(handler->HandleSyscall(nullptr, &lseek_args) == 0, "lseek should reposition interpreter file descriptors");

  FEXCore::HLE::SyscallArguments close_args {};
  close_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::close);
  close_args.Argument[1] = static_cast<uint64_t>(fd);
  require(handler->HandleSyscall(nullptr, &close_args) == 0, "close should release openat descriptors");
}

void test_minimal_darwin_syscall_handler_resolves_absolute_paths_inside_userland_root() {
  const auto root = make_temp_dir();
  const auto interpreter = root / "lib64" / "ld-linux-x86-64.so.2";
  write_file(interpreter, "guest-interpreter");
  ScopedEnvironmentOverride userland_root("IRIDIUM_USERLAND_ROOT", root.string().c_str());

  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  const char* guest_path = "/lib64/ld-linux-x86-64.so.2";
  FEXCore::HLE::SyscallArguments open_args {};
  open_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::open);
  open_args.Argument[1] = reinterpret_cast<uint64_t>(guest_path);
  open_args.Argument[2] = O_RDONLY;
  const int64_t fd = static_cast<int64_t>(handler->HandleSyscall(nullptr, &open_args));
  require(fd >= 0, "open should resolve absolute guest paths inside IRIDIUM_USERLAND_ROOT");

  char buffer[32] = {};
  require(::read(static_cast<int>(fd), buffer, sizeof(buffer) - 1) > 0, "test should read translated guest path contents");
  require(std::string(buffer) == "guest-interpreter", "translated guest path should read from the userland root");
  ::close(static_cast<int>(fd));
}

void test_minimal_darwin_syscall_handler_supports_loader_startup_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_rt_sigaction = 13;
  constexpr uint64_t linux_rt_sigprocmask = 14;
  constexpr uint64_t linux_getpid = 39;
  constexpr uint64_t linux_getppid = 110;
  constexpr uint64_t linux_sigaltstack = 131;
  constexpr uint64_t linux_gettid = 186;
  constexpr uint64_t linux_time = 201;
  constexpr uint64_t linux_set_tid_address = 218;
  constexpr uint64_t linux_clock_gettime = 228;
  constexpr uint64_t linux_set_robust_list = 273;
  constexpr uint64_t linux_clock_monotonic = 1;
  constexpr uint64_t linux_sig_ign = 1;
  constexpr uint64_t linux_sig_block = 0;
  constexpr uint64_t linux_sigusr1 = 10;

  struct LinuxKernelSigAction {
    uint64_t handler;
    uint64_t flags;
    uint64_t restorer;
    uint64_t mask;
  };

  LinuxKernelSigAction install_action {};
  install_action.handler = linux_sig_ign;
  install_action.flags = 0x04000000;
  install_action.restorer = 0x12340000;
  install_action.mask = 0x2;

  LinuxKernelSigAction previous_action {};
  FEXCore::HLE::SyscallArguments sigaction_args {};
  sigaction_args.Argument[0] = linux_rt_sigaction;
  sigaction_args.Argument[1] = linux_sigusr1;
  sigaction_args.Argument[2] = reinterpret_cast<uint64_t>(&install_action);
  sigaction_args.Argument[3] = reinterpret_cast<uint64_t>(&previous_action);
  sigaction_args.Argument[4] = sizeof(uint64_t);
  require(handler->HandleSyscall(nullptr, &sigaction_args) == 0, "rt_sigaction should accept loader signal setup");
  require(previous_action.handler == 0, "rt_sigaction should report the previous default handler");

  LinuxKernelSigAction queried_action {};
  FEXCore::HLE::SyscallArguments query_sigaction_args {};
  query_sigaction_args.Argument[0] = linux_rt_sigaction;
  query_sigaction_args.Argument[1] = linux_sigusr1;
  query_sigaction_args.Argument[2] = 0;
  query_sigaction_args.Argument[3] = reinterpret_cast<uint64_t>(&queried_action);
  query_sigaction_args.Argument[4] = sizeof(uint64_t);
  require(handler->HandleSyscall(nullptr, &query_sigaction_args) == 0, "rt_sigaction should allow action queries");
  require(queried_action.handler == linux_sig_ign, "rt_sigaction should remember the installed guest handler");
  require(queried_action.mask == install_action.mask, "rt_sigaction should preserve the guest signal mask");

  uint64_t signal_mask = 1ULL << (linux_sigusr1 - 1);
  uint64_t previous_mask = UINT64_MAX;
  FEXCore::HLE::SyscallArguments sigprocmask_args {};
  sigprocmask_args.Argument[0] = linux_rt_sigprocmask;
  sigprocmask_args.Argument[1] = linux_sig_block;
  sigprocmask_args.Argument[2] = reinterpret_cast<uint64_t>(&signal_mask);
  sigprocmask_args.Argument[3] = reinterpret_cast<uint64_t>(&previous_mask);
  sigprocmask_args.Argument[4] = sizeof(signal_mask);
  require(handler->HandleSyscall(nullptr, &sigprocmask_args) == 0, "rt_sigprocmask should accept loader masks");
  require(previous_mask == 0, "rt_sigprocmask should report the previous empty guest mask");

  struct LinuxStackT {
    uint64_t stack_pointer;
    int32_t flags;
    uint32_t padding;
    uint64_t size;
  };

  LinuxStackT install_stack {
    0x70000000,
    0,
    0,
    0x4000,
  };
  LinuxStackT old_stack {};
  FEXCore::HLE::SyscallArguments sigaltstack_args {};
  sigaltstack_args.Argument[0] = linux_sigaltstack;
  sigaltstack_args.Argument[1] = reinterpret_cast<uint64_t>(&install_stack);
  sigaltstack_args.Argument[2] = reinterpret_cast<uint64_t>(&old_stack);
  require(handler->HandleSyscall(nullptr, &sigaltstack_args) == 0, "sigaltstack should accept guest alternate signal stacks");
  require(old_stack.flags == 2, "sigaltstack should report the initial disabled alternate stack");

  LinuxStackT queried_stack {};
  FEXCore::HLE::SyscallArguments query_sigaltstack_args {};
  query_sigaltstack_args.Argument[0] = linux_sigaltstack;
  query_sigaltstack_args.Argument[1] = 0;
  query_sigaltstack_args.Argument[2] = reinterpret_cast<uint64_t>(&queried_stack);
  require(handler->HandleSyscall(nullptr, &query_sigaltstack_args) == 0, "sigaltstack should support guest stack queries");
  require(queried_stack.stack_pointer == install_stack.stack_pointer, "sigaltstack should remember the guest alternate stack pointer");
  require(queried_stack.size == install_stack.size, "sigaltstack should remember the guest alternate stack size");

  FEXCore::HLE::SyscallArguments invalid_sigset_args {};
  invalid_sigset_args.Argument[0] = linux_rt_sigaction;
  invalid_sigset_args.Argument[1] = linux_sigusr1;
  invalid_sigset_args.Argument[4] = 16;
  require(
    static_cast<int64_t>(handler->HandleSyscall(nullptr, &invalid_sigset_args)) == -EINVAL,
    "rt_sigaction should reject unexpected x86_64 sigset sizes"
  );

  FEXCore::HLE::SyscallArguments getpid_args {};
  getpid_args.Argument[0] = linux_getpid;
  require(handler->HandleSyscall(nullptr, &getpid_args) == getpid(), "getpid should mirror the host pid");

  FEXCore::HLE::SyscallArguments getppid_args {};
  getppid_args.Argument[0] = linux_getppid;
  require(handler->HandleSyscall(nullptr, &getppid_args) == getppid(), "getppid should mirror the host parent pid");

  FEXCore::HLE::SyscallArguments gettid_args {};
  gettid_args.Argument[0] = linux_gettid;
  const uint64_t tid = handler->HandleSyscall(nullptr, &gettid_args);
  require(static_cast<int64_t>(tid) > 0, "gettid should expose a positive thread id");

  int64_t observed_time = -1;
  FEXCore::HLE::SyscallArguments time_args {};
  time_args.Argument[0] = linux_time;
  time_args.Argument[1] = reinterpret_cast<uint64_t>(&observed_time);
  const auto time_result = handler->HandleSyscall(nullptr, &time_args);
  require(static_cast<int64_t>(time_result) > 0, "time should report Unix epoch seconds");
  require(observed_time == static_cast<int64_t>(time_result), "time should copy the result to the guest pointer");

  uint32_t clear_child_tid = 0;
  FEXCore::HLE::SyscallArguments set_tid_address_args {};
  set_tid_address_args.Argument[0] = linux_set_tid_address;
  set_tid_address_args.Argument[1] = reinterpret_cast<uint64_t>(&clear_child_tid);
  require(
    handler->HandleSyscall(nullptr, &set_tid_address_args) == tid,
    "set_tid_address should record no host state and return the current thread id"
  );

  timespec monotonic_time {};
  FEXCore::HLE::SyscallArguments clock_gettime_args {};
  clock_gettime_args.Argument[0] = linux_clock_gettime;
  clock_gettime_args.Argument[1] = linux_clock_monotonic;
  clock_gettime_args.Argument[2] = reinterpret_cast<uint64_t>(&monotonic_time);
  require(handler->HandleSyscall(nullptr, &clock_gettime_args) == 0, "clock_gettime should accept CLOCK_MONOTONIC");
  require(monotonic_time.tv_sec >= 0, "clock_gettime should write a non-negative seconds field");
  require(monotonic_time.tv_nsec >= 0 && monotonic_time.tv_nsec < 1000000000, "clock_gettime should write nanoseconds");

  FEXCore::HLE::SyscallArguments set_robust_list_args {};
  set_robust_list_args.Argument[0] = linux_set_robust_list;
  set_robust_list_args.Argument[1] = 0;
  set_robust_list_args.Argument[2] = 24;
  require(
    handler->HandleSyscall(nullptr, &set_robust_list_args) == 0,
    "set_robust_list should be accepted as a no-op before futex support exists"
  );
}

void test_minimal_darwin_syscall_handler_supports_audited_wine_startup_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  int pipe_fds[2] {-1, -1};
  require(::pipe(pipe_fds) == 0, "audit syscall test should create a host pipe");

  pollfd descriptor {pipe_fds[0], POLLIN, 0};
  FEXCore::HLE::SyscallArguments poll_args {};
  poll_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::poll);
  poll_args.Argument[1] = reinterpret_cast<uint64_t>(&descriptor);
  poll_args.Argument[2] = 1;
  poll_args.Argument[3] = 0;
  require(handler->HandleSyscall(nullptr, &poll_args) == 0, "poll should report an empty pipe as not ready");

  require(::write(pipe_fds[1], "abcd", 4) == 4, "audit syscall test should seed its pipe");
  descriptor.revents = 0;
  require(handler->HandleSyscall(nullptr, &poll_args) == 1, "poll should report readable guest descriptors");
  require((descriptor.revents & POLLIN) != 0, "poll should preserve Linux-compatible readiness flags");

  char first[2] {};
  char second[2] {};
  iovec read_vectors[] {{first, sizeof(first)}, {second, sizeof(second)}};
  FEXCore::HLE::SyscallArguments readv_args {};
  readv_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::readv);
  readv_args.Argument[1] = static_cast<uint64_t>(pipe_fds[0]);
  readv_args.Argument[2] = reinterpret_cast<uint64_t>(read_vectors);
  readv_args.Argument[3] = 2;
  require(handler->HandleSyscall(nullptr, &readv_args) == 4, "readv should fill multiple guest vectors");
  require(std::string(first, 2) == "ab" && std::string(second, 2) == "cd", "readv should preserve guest byte order");

  timespec zero_timeout {};
  FEXCore::HLE::SyscallArguments ppoll_args {};
  ppoll_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::ppoll);
  ppoll_args.Argument[1] = reinterpret_cast<uint64_t>(&descriptor);
  ppoll_args.Argument[2] = 1;
  ppoll_args.Argument[3] = reinterpret_cast<uint64_t>(&zero_timeout);
  require(handler->HandleSyscall(nullptr, &ppoll_args) == 0, "ppoll should honor a zero guest timeout");

  std::array<uint8_t, 32> random_bytes {};
  FEXCore::HLE::SyscallArguments random_args {};
  random_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::getrandom);
  random_args.Argument[1] = reinterpret_cast<uint64_t>(random_bytes.data());
  random_args.Argument[2] = random_bytes.size();
  require(handler->HandleSyscall(nullptr, &random_args) == random_bytes.size(), "getrandom should fill the requested guest buffer");

  timeval wall_clock {};
  FEXCore::HLE::SyscallArguments time_args {};
  time_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::gettimeofday);
  time_args.Argument[1] = reinterpret_cast<uint64_t>(&wall_clock);
  require(handler->HandleSyscall(nullptr, &time_args) == 0 && wall_clock.tv_sec > 0, "gettimeofday should return wall-clock time");

  FEXCore::HLE::SyscallArguments sleep_args {};
  sleep_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::nanosleep);
  sleep_args.Argument[1] = reinterpret_cast<uint64_t>(&zero_timeout);
  require(handler->HandleSyscall(nullptr, &sleep_args) == 0, "nanosleep should accept a zero-duration guest request");

  FEXCore::HLE::SyscallArguments clock_sleep_args {};
  clock_sleep_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::clock_nanosleep);
  clock_sleep_args.Argument[1] = 1;
  clock_sleep_args.Argument[2] = 0;
  clock_sleep_args.Argument[3] = reinterpret_cast<uint64_t>(&zero_timeout);
  require(
    handler->HandleSyscall(nullptr, &clock_sleep_args) == 0,
    "clock_nanosleep should accept a zero-duration monotonic request"
  );

  timespec elapsed_deadline {};
  clock_sleep_args.Argument[2] = 1;
  clock_sleep_args.Argument[3] = reinterpret_cast<uint64_t>(&elapsed_deadline);
  require(
    handler->HandleSyscall(nullptr, &clock_sleep_args) == 0,
    "clock_nanosleep should immediately accept an elapsed absolute deadline"
  );

  clock_sleep_args.Argument[2] = 2;
  require(
    static_cast<int64_t>(handler->HandleSyscall(nullptr, &clock_sleep_args)) == -EINVAL,
    "clock_nanosleep should reject unsupported Linux flags"
  );

  FEXCore::HLE::SyscallArguments userfaultfd_args {};
  userfaultfd_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::userfaultfd);
  require(
    static_cast<int64_t>(handler->HandleSyscall(nullptr, &userfaultfd_args)) == -ENOSYS,
    "userfaultfd should select Wine's portable write-watch fallback without an unsupported-syscall warning"
  );

  FEXCore::HLE::SyscallArguments access_args {};
  access_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::faccessat2);
  access_args.Argument[1] = static_cast<uint64_t>(static_cast<int64_t>(-100));
  access_args.Argument[2] = reinterpret_cast<uint64_t>("/tmp");
  access_args.Argument[3] = F_OK;
  require(handler->HandleSyscall(nullptr, &access_args) == 0, "faccessat2 should translate Wine's absolute path probes");

  std::array<uint8_t, 120> statfs_buffer {};
  const int temp_directory_fd = ::open("/tmp", O_RDONLY);
  require(temp_directory_fd >= 0, "audit syscall test should open its filesystem probe directory");
  FEXCore::HLE::SyscallArguments statfs_args {};
  statfs_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::fstatfs);
  statfs_args.Argument[1] = static_cast<uint64_t>(temp_directory_fd);
  statfs_args.Argument[2] = reinterpret_cast<uint64_t>(statfs_buffer.data());
  require(handler->HandleSyscall(nullptr, &statfs_args) == 0, "fstatfs should emit an x86-64 Linux-shaped result");
  ::close(temp_directory_fd);

  uint32_t filesystem_flags = UINT32_MAX;
  FEXCore::HLE::SyscallArguments ioctl_args {};
  ioctl_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::ioctl);
  ioctl_args.Argument[1] = static_cast<uint64_t>(pipe_fds[0]);
  ioctl_args.Argument[2] = 0x80086601UL;
  ioctl_args.Argument[3] = reinterpret_cast<uint64_t>(&filesystem_flags);
  require(handler->HandleSyscall(nullptr, &ioctl_args) == 0 && filesystem_flags == 0, "ioctl should answer Wine's FS_IOC_GETFLAGS probe conservatively");

  FEXCore::HLE::SyscallArguments dup_args {};
  dup_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::dup);
  dup_args.Argument[1] = static_cast<uint64_t>(pipe_fds[0]);
  const int duplicated_fd = static_cast<int>(handler->HandleSyscall(nullptr, &dup_args));
  require(duplicated_fd >= 0, "dup should create a usable guest descriptor");
  ::close(duplicated_fd);

  const mode_t original_mask = ::umask(0);
  ::umask(original_mask);
  FEXCore::HLE::SyscallArguments umask_args {};
  umask_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::umask);
  umask_args.Argument[1] = 0077;
  require(handler->HandleSyscall(nullptr, &umask_args) == original_mask, "umask should report the previous process mask");
  ::umask(original_mask);

  ::close(pipe_fds[0]);
  ::close(pipe_fds[1]);
}

void test_minimal_darwin_syscall_handler_supports_loader_io_and_identity_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_writev = 20;
  constexpr uint64_t linux_uname = 63;
  constexpr uint64_t linux_fcntl = 72;
  constexpr uint64_t linux_getcwd = 79;
  constexpr uint64_t linux_chdir = 80;
  constexpr uint64_t linux_mkdir = 83;
  constexpr uint64_t linux_symlink = 88;
  constexpr uint64_t linux_readlink = 89;
  constexpr uint64_t linux_readlinkat = 267;
  constexpr uint64_t linux_at_fdcwd = static_cast<uint64_t>(-100);
  constexpr uint64_t linux_f_getfd = 1;
  constexpr uint64_t linux_f_setfd = 2;
  constexpr uint64_t linux_fd_cloexec = 1;

  int pipe_fds[2] = {-1, -1};
  require(pipe(pipe_fds) == 0, "test should create a pipe for writev syscall verification");

  const char first[] = "ld";
  const char second[] = "-linux";
  iovec vectors[2] {};
  vectors[0].iov_base = const_cast<char*>(first);
  vectors[0].iov_len = 2;
  vectors[1].iov_base = const_cast<char*>(second);
  vectors[1].iov_len = 6;

  FEXCore::HLE::SyscallArguments writev_args {};
  writev_args.Argument[0] = linux_writev;
  writev_args.Argument[1] = static_cast<uint64_t>(pipe_fds[1]);
  writev_args.Argument[2] = reinterpret_cast<uint64_t>(vectors);
  writev_args.Argument[3] = 2;
  require(handler->HandleSyscall(nullptr, &writev_args) == 8, "writev should write guest iovec bytes");

  char pipe_buffer[8] = {};
  require(read(pipe_fds[0], pipe_buffer, sizeof(pipe_buffer)) == 8, "test should read back writev bytes");
  require(std::string(pipe_buffer, sizeof(pipe_buffer)) == "ld-linux", "writev should preserve vector ordering");
  close(pipe_fds[0]);
  close(pipe_fds[1]);

  char cwd_buffer[PATH_MAX] = {};
  FEXCore::HLE::SyscallArguments getcwd_args {};
  getcwd_args.Argument[0] = linux_getcwd;
  getcwd_args.Argument[1] = reinterpret_cast<uint64_t>(cwd_buffer);
  getcwd_args.Argument[2] = sizeof(cwd_buffer);
  const uint64_t cwd_length = handler->HandleSyscall(nullptr, &getcwd_args);
  require(static_cast<int64_t>(cwd_length) > 0, "getcwd should write the current working directory");
  require(cwd_buffer[0] == '/', "getcwd should return an absolute path");

  const fs::path original_cwd = fs::current_path();
  const fs::path chdir_target = make_temp_dir();
  const std::string chdir_target_string = chdir_target.string();
  FEXCore::HLE::SyscallArguments chdir_args {};
  chdir_args.Argument[0] = linux_chdir;
  chdir_args.Argument[1] = reinterpret_cast<uint64_t>(chdir_target_string.c_str());
  require(handler->HandleSyscall(nullptr, &chdir_args) == 0, "chdir should switch to an existing guest directory");
  const bool chdir_reached_target = fs::equivalent(fs::current_path(), chdir_target);
  fs::current_path(original_cwd);
  require(chdir_reached_target, "chdir should update the host cwd used by Wine");

  const fs::path mkdir_target = chdir_target / "dosdevices";
  const std::string mkdir_target_string = mkdir_target.string();
  FEXCore::HLE::SyscallArguments mkdir_args {};
  mkdir_args.Argument[0] = linux_mkdir;
  mkdir_args.Argument[1] = reinterpret_cast<uint64_t>(mkdir_target_string.c_str());
  mkdir_args.Argument[2] = 0777;
  require(handler->HandleSyscall(nullptr, &mkdir_args) == 0, "mkdir should create Wine prefix directories");
  require(fs::is_directory(mkdir_target), "mkdir should create the requested directory");

  const char symlink_target[] = "../drive_c";
  const fs::path symlink_path = mkdir_target / "c:";
  const std::string symlink_path_string = symlink_path.string();
  FEXCore::HLE::SyscallArguments symlink_args {};
  symlink_args.Argument[0] = linux_symlink;
  symlink_args.Argument[1] = reinterpret_cast<uint64_t>(symlink_target);
  symlink_args.Argument[2] = reinterpret_cast<uint64_t>(symlink_path_string.c_str());
  require(handler->HandleSyscall(nullptr, &symlink_args) == 0, "symlink should create Wine dosdevices mappings");
  require(fs::is_symlink(symlink_path), "symlink should create the requested link");

  struct LinuxUtsName {
    char sysname[65];
    char nodename[65];
    char release[65];
    char version[65];
    char machine[65];
    char domainname[65];
  } uts {};

  FEXCore::HLE::SyscallArguments uname_args {};
  uname_args.Argument[0] = linux_uname;
  uname_args.Argument[1] = reinterpret_cast<uint64_t>(&uts);
  require(handler->HandleSyscall(nullptr, &uname_args) == 0, "uname should populate a Linux-shaped utsname");
  require(std::string(uts.sysname) == "Linux", "uname should report Linux to the guest loader");
  require(std::string(uts.machine) == "x86_64", "uname should report the guest machine");

  const auto root = make_temp_dir();
  const auto target = root / "target.txt";
  const auto link = root / "loader-link";
  write_file(target, "loader");
  require(symlink(target.c_str(), link.c_str()) == 0, "test should create a symlink for readlinkat");

  char link_buffer[PATH_MAX] = {};
  FEXCore::HLE::SyscallArguments readlinkat_args {};
  readlinkat_args.Argument[0] = linux_readlinkat;
  readlinkat_args.Argument[1] = linux_at_fdcwd;
  readlinkat_args.Argument[2] = reinterpret_cast<uint64_t>(link.c_str());
  readlinkat_args.Argument[3] = reinterpret_cast<uint64_t>(link_buffer);
  readlinkat_args.Argument[4] = sizeof(link_buffer);
  const uint64_t link_length = handler->HandleSyscall(nullptr, &readlinkat_args);
  require(static_cast<int64_t>(link_length) > 0, "readlinkat should return the symlink target length");
  require(std::string(link_buffer, static_cast<size_t>(link_length)) == target, "readlinkat should copy target bytes");

  char plain_link_buffer[PATH_MAX] = {};
  FEXCore::HLE::SyscallArguments readlink_args {};
  readlink_args.Argument[0] = linux_readlink;
  readlink_args.Argument[1] = reinterpret_cast<uint64_t>(link.c_str());
  readlink_args.Argument[2] = reinterpret_cast<uint64_t>(plain_link_buffer);
  readlink_args.Argument[3] = sizeof(plain_link_buffer);
  const uint64_t plain_link_length = handler->HandleSyscall(nullptr, &readlink_args);
  require(static_cast<int64_t>(plain_link_length) > 0, "readlink should return the symlink target length");
  require(std::string(plain_link_buffer, static_cast<size_t>(plain_link_length)) == target, "readlink should copy target bytes");

  FEXCore::HLE::SyscallArguments open_args {};
  open_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::open);
  open_args.Argument[1] = reinterpret_cast<uint64_t>(target.c_str());
  open_args.Argument[2] = O_RDONLY;
  const int64_t fd = static_cast<int64_t>(handler->HandleSyscall(nullptr, &open_args));
  require(fd >= 0, "test should open a descriptor for fcntl verification");

  FEXCore::HLE::SyscallArguments setfd_args {};
  setfd_args.Argument[0] = linux_fcntl;
  setfd_args.Argument[1] = static_cast<uint64_t>(fd);
  setfd_args.Argument[2] = linux_f_setfd;
  setfd_args.Argument[3] = linux_fd_cloexec;
  require(handler->HandleSyscall(nullptr, &setfd_args) == 0, "fcntl F_SETFD should accept FD_CLOEXEC");

  FEXCore::HLE::SyscallArguments getfd_args {};
  getfd_args.Argument[0] = linux_fcntl;
  getfd_args.Argument[1] = static_cast<uint64_t>(fd);
  getfd_args.Argument[2] = linux_f_getfd;
  require(handler->HandleSyscall(nullptr, &getfd_args) == linux_fd_cloexec, "fcntl F_GETFD should return FD_CLOEXEC");

  FEXCore::HLE::SyscallArguments close_args {};
  close_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::close);
  close_args.Argument[1] = static_cast<uint64_t>(fd);
  require(handler->HandleSyscall(nullptr, &close_args) == 0, "close should release fcntl test descriptors");
}

void test_minimal_darwin_syscall_handler_supports_linux_stat_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_fstat = 5;
  constexpr uint64_t linux_newfstatat = 262;
  constexpr uint64_t linux_at_fdcwd = static_cast<uint64_t>(-100);

  struct LinuxStat {
    uint64_t dev;
    uint64_t ino;
    uint64_t nlink;
    uint32_t mode;
    uint32_t uid;
    uint32_t gid;
    uint32_t pad0;
    uint64_t rdev;
    int64_t size;
    int64_t blksize;
    int64_t blocks;
    int64_t atime_sec;
    int64_t atime_nsec;
    int64_t mtime_sec;
    int64_t mtime_nsec;
    int64_t ctime_sec;
    int64_t ctime_nsec;
    int64_t unused[3];
  };

  static_assert(sizeof(LinuxStat) == 144, "x86_64 Linux stat layout should stay stable");

  const auto root = make_temp_dir();
  const auto payload = root / "module.so";
  write_file(payload, "dynamic-loader-payload");

  FEXCore::HLE::SyscallArguments open_args {};
  open_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::open);
  open_args.Argument[1] = reinterpret_cast<uint64_t>(payload.c_str());
  open_args.Argument[2] = O_RDONLY;
  const int64_t fd = static_cast<int64_t>(handler->HandleSyscall(nullptr, &open_args));
  require(fd >= 0, "test should open a descriptor for fstat verification");

  LinuxStat fd_stat {};
  FEXCore::HLE::SyscallArguments fstat_args {};
  fstat_args.Argument[0] = linux_fstat;
  fstat_args.Argument[1] = static_cast<uint64_t>(fd);
  fstat_args.Argument[2] = reinterpret_cast<uint64_t>(&fd_stat);
  require(handler->HandleSyscall(nullptr, &fstat_args) == 0, "fstat should populate a Linux-shaped stat buffer");
  require(fd_stat.size == 22, "fstat should translate file size");
  require((fd_stat.mode & S_IFMT) == S_IFREG, "fstat should preserve regular-file mode bits");
  require(fd_stat.nlink >= 1, "fstat should translate link count");

  LinuxStat path_stat {};
  FEXCore::HLE::SyscallArguments newfstatat_args {};
  newfstatat_args.Argument[0] = linux_newfstatat;
  newfstatat_args.Argument[1] = linux_at_fdcwd;
  newfstatat_args.Argument[2] = reinterpret_cast<uint64_t>(payload.c_str());
  newfstatat_args.Argument[3] = reinterpret_cast<uint64_t>(&path_stat);
  newfstatat_args.Argument[4] = 0;
  require(
    handler->HandleSyscall(nullptr, &newfstatat_args) == 0,
    "newfstatat should populate a Linux-shaped stat buffer"
  );
  require(path_stat.size == fd_stat.size, "newfstatat should translate file size");
  require(path_stat.ino == fd_stat.ino, "newfstatat should translate inode identity");

  FEXCore::HLE::SyscallArguments close_args {};
  close_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::close);
  close_args.Argument[1] = static_cast<uint64_t>(fd);
  require(handler->HandleSyscall(nullptr, &close_args) == 0, "close should release fstat test descriptors");
}

void test_minimal_darwin_syscall_handler_supports_linux_getdents64() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_getdents64 = 217;
  constexpr uint64_t linux_at_fdcwd = static_cast<uint64_t>(-100);
  constexpr uint64_t linux_o_rdonly = 0;
  constexpr uint64_t linux_o_directory = 0x10000;

  struct LinuxDirent64Header {
    uint64_t ino;
    int64_t offset;
    uint16_t record_length;
    uint8_t type;
  };

  const auto root = make_temp_dir();
  write_file(root / "alpha.dll", "alpha");
  write_file(root / "beta.dll", "beta");

  FEXCore::HLE::SyscallArguments openat_args {};
  openat_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::openat);
  openat_args.Argument[1] = linux_at_fdcwd;
  openat_args.Argument[2] = reinterpret_cast<uint64_t>(root.c_str());
  openat_args.Argument[3] = linux_o_rdonly | linux_o_directory;
  const int64_t fd = static_cast<int64_t>(handler->HandleSyscall(nullptr, &openat_args));
  require(fd >= 0, "test should open a directory descriptor for getdents64 verification");

  std::array<char, 1024> buffer {};
  FEXCore::HLE::SyscallArguments getdents_args {};
  getdents_args.Argument[0] = linux_getdents64;
  getdents_args.Argument[1] = static_cast<uint64_t>(fd);
  getdents_args.Argument[2] = reinterpret_cast<uint64_t>(buffer.data());
  getdents_args.Argument[3] = buffer.size();
  const int64_t bytes = static_cast<int64_t>(handler->HandleSyscall(nullptr, &getdents_args));
  require(bytes > 0, "getdents64 should return packed Linux directory records");

  bool saw_alpha = false;
  bool saw_beta = false;
  size_t offset = 0;
  while (offset < static_cast<size_t>(bytes)) {
    const auto* header = reinterpret_cast<const LinuxDirent64Header*>(buffer.data() + offset);
    require(header->record_length >= 20, "getdents64 records should include a Linux dirent64 header and name");
    const char* name = buffer.data() + offset + 19;
    if (std::strcmp(name, "alpha.dll") == 0) {
      saw_alpha = true;
      require(header->type == DT_REG, "getdents64 should translate regular-file d_type");
    }
    if (std::strcmp(name, "beta.dll") == 0) {
      saw_beta = true;
      require(header->type == DT_REG, "getdents64 should translate regular-file d_type");
    }
    offset += header->record_length;
  }
  require(saw_alpha && saw_beta, "getdents64 should include staged directory entries");

  FEXCore::HLE::SyscallArguments close_args {};
  close_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::close);
  close_args.Argument[1] = static_cast<uint64_t>(fd);
  require(handler->HandleSyscall(nullptr, &close_args) == 0, "close should release getdents64 descriptors");
}

void test_minimal_darwin_syscall_handler_supports_futex_wait_and_wake() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_futex = 202;
  constexpr uint64_t linux_futex_wait = 0;
  constexpr uint64_t linux_futex_wake = 1;
  constexpr uint64_t linux_futex_private_flag = 128;

  struct LinuxTimespec {
    int64_t sec;
    int64_t nsec;
  };

  uint32_t futex_word = 2;
  FEXCore::HLE::SyscallArguments wait_mismatch_args {};
  wait_mismatch_args.Argument[0] = linux_futex;
  wait_mismatch_args.Argument[1] = reinterpret_cast<uint64_t>(&futex_word);
  wait_mismatch_args.Argument[2] = linux_futex_wait | linux_futex_private_flag;
  wait_mismatch_args.Argument[3] = 1;
  require(
    static_cast<int64_t>(handler->HandleSyscall(nullptr, &wait_mismatch_args)) == -EAGAIN,
    "FUTEX_WAIT should return EAGAIN when the futex word does not match"
  );

  futex_word = 1;
  LinuxTimespec no_wait_timeout {};
  FEXCore::HLE::SyscallArguments wait_timeout_args {};
  wait_timeout_args.Argument[0] = linux_futex;
  wait_timeout_args.Argument[1] = reinterpret_cast<uint64_t>(&futex_word);
  wait_timeout_args.Argument[2] = linux_futex_wait | linux_futex_private_flag;
  wait_timeout_args.Argument[3] = 1;
  wait_timeout_args.Argument[4] = reinterpret_cast<uint64_t>(&no_wait_timeout);
  require(
    static_cast<int64_t>(handler->HandleSyscall(nullptr, &wait_timeout_args)) == -ETIMEDOUT,
    "FUTEX_WAIT with a zero timeout should report ETIMEDOUT instead of blocking the host"
  );

  FEXCore::HLE::SyscallArguments wake_args {};
  wake_args.Argument[0] = linux_futex;
  wake_args.Argument[1] = reinterpret_cast<uint64_t>(&futex_word);
  wake_args.Argument[2] = linux_futex_wake | linux_futex_private_flag;
  wake_args.Argument[3] = 1;
  uint64_t waiter_result = static_cast<uint64_t>(-EINPROGRESS);
  std::thread waiter([&] {
    FEXCore::HLE::SyscallArguments wait_args {};
    wait_args.Argument[0] = linux_futex;
    wait_args.Argument[1] = reinterpret_cast<uint64_t>(&futex_word);
    wait_args.Argument[2] = linux_futex_wait | linux_futex_private_flag;
    wait_args.Argument[3] = 1;
    waiter_result = handler->HandleSyscall(nullptr, &wait_args);
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(10));
  require(handler->HandleSyscall(nullptr, &wake_args) == 1, "FUTEX_WAKE should release the requested waiter count");
  waiter.join();
  require(waiter_result == 0, "FUTEX_WAIT should resume after FUTEX_WAKE");

  FEXCore::HLE::SyscallArguments null_wait_args {};
  null_wait_args.Argument[0] = linux_futex;
  null_wait_args.Argument[1] = 0;
  null_wait_args.Argument[2] = linux_futex_wait;
  require(
    static_cast<int64_t>(handler->HandleSyscall(nullptr, &null_wait_args)) == -EFAULT,
    "futex should reject null guest futex addresses"
  );
}

void test_minimal_darwin_syscall_handler_supports_cpu_probe_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  constexpr uint64_t linux_sched_setaffinity = 203;
  constexpr uint64_t linux_sched_getaffinity = 204;
  constexpr uint64_t linux_prlimit64 = 302;
  constexpr uint64_t linux_getcpu = 309;
  constexpr uint64_t linux_rseq = 334;
  constexpr uint64_t linux_rlimit_stack = 3;

  uint32_t cpu = UINT32_MAX;
  uint32_t node = UINT32_MAX;
  FEXCore::HLE::SyscallArguments getcpu_args {};
  getcpu_args.Argument[0] = linux_getcpu;
  getcpu_args.Argument[1] = reinterpret_cast<uint64_t>(&cpu);
  getcpu_args.Argument[2] = reinterpret_cast<uint64_t>(&node);
  require(handler->HandleSyscall(nullptr, &getcpu_args) == 0, "getcpu should satisfy glibc CPU probing");
  require(cpu == 0, "getcpu should report a deterministic guest CPU");
  require(node == 0, "getcpu should report a deterministic guest NUMA node");

  uint64_t affinity_mask = 0;
  FEXCore::HLE::SyscallArguments getaffinity_args {};
  getaffinity_args.Argument[0] = linux_sched_getaffinity;
  getaffinity_args.Argument[1] = 0;
  getaffinity_args.Argument[2] = sizeof(affinity_mask);
  getaffinity_args.Argument[3] = reinterpret_cast<uint64_t>(&affinity_mask);
  require(
    handler->HandleSyscall(nullptr, &getaffinity_args) == sizeof(affinity_mask),
    "sched_getaffinity should return the copied mask size"
  );
  require(affinity_mask == 1, "sched_getaffinity should expose one deterministic guest CPU");

  FEXCore::HLE::SyscallArguments setaffinity_args {};
  setaffinity_args.Argument[0] = linux_sched_setaffinity;
  setaffinity_args.Argument[1] = 0;
  setaffinity_args.Argument[2] = sizeof(affinity_mask);
  setaffinity_args.Argument[3] = reinterpret_cast<uint64_t>(&affinity_mask);
  require(handler->HandleSyscall(nullptr, &setaffinity_args) == 0, "sched_setaffinity should accept guest hints");

  struct LinuxRseqArea {
    uint32_t cpu_id_start;
    uint32_t cpu_id;
    uint64_t rseq_cs;
    uint32_t flags;
  };
  LinuxRseqArea rseq_area {
    UINT32_MAX,
    UINT32_MAX,
    0,
    0,
  };
  FEXCore::HLE::SyscallArguments rseq_args {};
  rseq_args.Argument[0] = linux_rseq;
  rseq_args.Argument[1] = reinterpret_cast<uint64_t>(&rseq_area);
  rseq_args.Argument[2] = 0x20;
  rseq_args.Argument[3] = 0;
  rseq_args.Argument[4] = 0x53053053;
  require(
    handler->HandleSyscall(nullptr, &rseq_args) == 0,
    "rseq should register a single deterministic guest CPU area"
  );
  require(rseq_area.cpu_id_start == 0, "rseq registration should report CPU 0 as the starting CPU");
  require(rseq_area.cpu_id == 0, "rseq registration should report CPU 0 as the current CPU");
  require(rseq_area.rseq_cs == 0, "rseq registration should leave the active critical section clear");
  require(rseq_area.flags == 0, "rseq registration should leave flags clear");

  struct LinuxRLimit64 {
    uint64_t current;
    uint64_t maximum;
  };
  LinuxRLimit64 stack_limit {};
  FEXCore::HLE::SyscallArguments prlimit_args {};
  prlimit_args.Argument[0] = linux_prlimit64;
  prlimit_args.Argument[1] = 0;
  prlimit_args.Argument[2] = linux_rlimit_stack;
  prlimit_args.Argument[3] = 0;
  prlimit_args.Argument[4] = reinterpret_cast<uint64_t>(&stack_limit);
  require(handler->HandleSyscall(nullptr, &prlimit_args) == 0, "prlimit64 should support stack limit queries");
  require(stack_limit.current > 0, "prlimit64 stack query should report a non-zero current limit");
  require(stack_limit.maximum >= stack_limit.current, "prlimit64 stack query should report a coherent maximum limit");
}

void test_minimal_darwin_syscall_handler_supports_runtime_environment_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  struct LinuxSysInfo {
    int64_t uptime;
    uint64_t loads[3];
    uint64_t totalram;
    uint64_t freeram;
    uint64_t sharedram;
    uint64_t bufferram;
    uint64_t totalswap;
    uint64_t freeswap;
    uint16_t procs;
    uint16_t padding;
    uint64_t totalhigh;
    uint64_t freehigh;
    uint32_t mem_unit;
  } info {};
  static_assert(sizeof(LinuxSysInfo) == 112, "x86_64 Linux sysinfo layout should stay stable");

  FEXCore::HLE::SyscallArguments sysinfo_args {};
  sysinfo_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::sysinfo);
  sysinfo_args.Argument[1] = reinterpret_cast<uint64_t>(&info);
  require(handler->HandleSyscall(nullptr, &sysinfo_args) == 0, "sysinfo should populate Linux runtime information");
  require(info.uptime >= 0, "sysinfo should report a non-negative uptime");
  require(info.totalram > 0, "sysinfo should report non-zero physical memory");
  require(info.freeram <= info.totalram, "sysinfo free memory should not exceed total memory");
  require(info.mem_unit == 1, "sysinfo byte counts should use a one-byte memory unit");

  timespec resolution {};
  FEXCore::HLE::SyscallArguments clock_getres_args {};
  clock_getres_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::clock_getres);
  clock_getres_args.Argument[1] = 1;
  clock_getres_args.Argument[2] = reinterpret_cast<uint64_t>(&resolution);
  require(handler->HandleSyscall(nullptr, &clock_getres_args) == 0, "clock_getres should translate CLOCK_MONOTONIC");
  require(resolution.tv_sec >= 0 && resolution.tv_nsec >= 0, "clock_getres should return a valid resolution");

  const int original_directory = ::open(".", O_RDONLY);
  require(original_directory >= 0, "test should preserve the original working directory");
  const auto target_directory = make_temp_dir();
  const int target_descriptor = ::open(target_directory.c_str(), O_RDONLY);
  require(target_descriptor >= 0, "test should open the target working directory");

  FEXCore::HLE::SyscallArguments fchdir_args {};
  fchdir_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::fchdir);
  fchdir_args.Argument[1] = static_cast<uint64_t>(target_descriptor);
  require(handler->HandleSyscall(nullptr, &fchdir_args) == 0, "fchdir should select an open guest directory");

  char working_directory[PATH_MAX] {};
  require(::getcwd(working_directory, sizeof(working_directory)) != nullptr, "test should read the updated working directory");
  require(fs::equivalent(working_directory, target_directory), "fchdir should update the process working directory");

  fchdir_args.Argument[1] = static_cast<uint64_t>(original_directory);
  require(handler->HandleSyscall(nullptr, &fchdir_args) == 0, "fchdir should restore the original working directory");
  require(::close(target_descriptor) == 0, "test should close the target directory descriptor");
  require(::close(original_directory) == 0, "test should close the original directory descriptor");
}

void test_minimal_darwin_syscall_handler_traps_guest_exit_group() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  int exit_code = -1;
  const bool trapped = iridium::fex::ios::RunWithGuestExitTrap(
    [](void* raw_handler) {
      auto* syscall_handler = static_cast<FEXCore::HLE::SyscallHandler*>(raw_handler);
      FEXCore::HLE::SyscallArguments exit_args {};
      exit_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::exit_group);
      exit_args.Argument[1] = 42;
      (void)syscall_handler->HandleSyscall(nullptr, &exit_args);
    },
    handler.get(),
    exit_code
  );

  require(trapped, "exit_group should leave guest execution through the exit trap");
  require(exit_code == 42, "exit_group trap should preserve the guest exit status");
}

void test_embedded_wineserver_can_address_registered_guest_threads() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  FEXCore::HLE::SyscallArguments gettid_args {};
  gettid_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::gettid);
  const uint64_t guest_thread_identifier = handler->HandleSyscall(nullptr, &gettid_args);
  require(guest_thread_identifier != 0, "gettid should register the main translated guest thread");
  require(
    iridium_fex_ios_signal_guest_thread(guest_thread_identifier, SIGUSR1) == 0,
    "the embedded Wine server should be able to queue a cooperative guest-thread interrupt"
  );
  require(
    iridium_fex_ios_signal_guest_thread(guest_thread_identifier + 0x100000, SIGUSR1) == ESRCH,
    "the embedded Wine server should reject stale guest thread identifiers"
  );
  require(
    iridium_fex_ios_signal_guest_thread(guest_thread_identifier, SIGTERM) == ENOTSUP,
    "the embedded bridge should reject signals without defined guest semantics"
  );
}

void test_guest_execution_trap_records_fatal_host_signal() {
  iridium::fex::ios::GuestExecutionTrapResult result {};
  const bool trapped = iridium::fex::ios::RunWithGuestExecutionTrap(
    [](void*) {
      volatile int* fault = nullptr;
      *fault = 1;
    },
    nullptr,
    result
  );

  require(trapped, "guest execution trap should catch fatal host signals");
  require(result.fatal_signal, "guest execution trap should classify the trap as a fatal signal");
  require(result.signal_number == SIGSEGV || result.signal_number == SIGBUS, "guest execution trap should record the host fault signal");
  require(!result.exited, "fatal signal trap should not look like a normal guest exit");
}

void test_minimal_darwin_syscall_handler_spawns_host_wineserver_helper() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  const char helper_path[] = "/usr/bin/true";
  FEXCore::HLE::SyscallArguments spawn_args {};
  spawn_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::iridium_spawn_host_wineserver);
  spawn_args.Argument[1] = reinterpret_cast<uint64_t>(helper_path);
  spawn_args.Argument[2] = 0;
  const int64_t child_pid = static_cast<int64_t>(handler->HandleSyscall(nullptr, &spawn_args));
  require(child_pid > 0, "host wineserver helper syscall should spawn a native helper process");

  int status = -1;
  FEXCore::HLE::SyscallArguments wait_args {};
  wait_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::wait4);
  wait_args.Argument[1] = static_cast<uint64_t>(child_pid);
  wait_args.Argument[2] = reinterpret_cast<uint64_t>(&status);
  wait_args.Argument[3] = 0;
  require(
    static_cast<int64_t>(handler->HandleSyscall(nullptr, &wait_args)) == child_pid,
    "wait4 should observe the native helper process"
  );
  require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "host wineserver helper should exit successfully");
}

int embedded_wine_server_test_debug_enabled = -1;
std::vector<std::string> observed_runtime_milestones;

int start_embedded_wine_server_for_test(int debug_enabled, char*, size_t) {
  embedded_wine_server_test_debug_enabled = debug_enabled;
  return 0;
}

void observe_runtime_milestone_for_test(const char* milestone, void*) {
  observed_runtime_milestones.emplace_back(milestone != nullptr ? milestone : "");
}

void test_minimal_darwin_syscall_handler_starts_registered_embedded_wineserver() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  embedded_wine_server_test_debug_enabled = -1;
  observed_runtime_milestones.clear();
  iridium::fex::ios::SetRuntimeMilestoneObserver(observe_runtime_milestone_for_test, nullptr);
  iridium_fex_ios_register_embedded_wine_server_start(start_embedded_wine_server_for_test);

  const char empty_path[] = "";
  FEXCore::HLE::SyscallArguments spawn_args {};
  spawn_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::iridium_spawn_host_wineserver);
  spawn_args.Argument[1] = reinterpret_cast<uint64_t>(empty_path);
  spawn_args.Argument[2] = 1;
  require(
    handler->HandleSyscall(nullptr, &spawn_args) == 0,
    "registered embedded Wine server should start without spawning a child process"
  );
  require(embedded_wine_server_test_debug_enabled == 1, "embedded Wine server callback should receive the debug flag");
  require(
    observed_runtime_milestones == std::vector<std::string> {"wineServerReady"},
    "embedded Wine server startup should emit the server-ready milestone"
  );

  FEXCore::HLE::SyscallArguments process_args {};
  process_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::iridium_windows_process_started);
  require(handler->HandleSyscall(nullptr, &process_args) == 0, "Windows process milestone syscall should succeed");
  require(
    observed_runtime_milestones == std::vector<std::string>({"wineServerReady", "windowsProcessStarted"}),
    "Windows process initialization should emit a separate milestone"
  );

  iridium_fex_ios_register_embedded_wine_server_start(nullptr);
  iridium::fex::ios::SetRuntimeMilestoneObserver(nullptr, nullptr);
}

void test_minimal_darwin_syscall_handler_translates_unix_socket_connect() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  require(handler != nullptr, "minimal Darwin syscall handler should be constructible");

  const fs::path socket_path = make_temp_dir() / "bridge.sock";
  const int server_fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
  require(server_fd >= 0, "test should create a native Unix socket");

  sockaddr_un server_addr {};
  server_addr.sun_family = AF_UNIX;
  std::strncpy(server_addr.sun_path, socket_path.c_str(), sizeof(server_addr.sun_path) - 1);
#if defined(__APPLE__)
  server_addr.sun_len = static_cast<unsigned char>(SUN_LEN(&server_addr));
#endif
  require(::bind(server_fd, reinterpret_cast<const sockaddr*>(&server_addr), SUN_LEN(&server_addr)) == 0, "test should bind socket");
  require(::listen(server_fd, 1) == 0, "test should listen on socket");

  FEXCore::HLE::SyscallArguments socket_args {};
  socket_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::socket);
  socket_args.Argument[1] = 1;
  socket_args.Argument[2] = 1;
  socket_args.Argument[3] = 0;
  const int client_fd = static_cast<int>(handler->HandleSyscall(nullptr, &socket_args));
  require(client_fd >= 0, "minimal Darwin syscall handler should translate Linux AF_UNIX socket");

  struct LinuxSockAddrUnix {
    uint16_t family;
    char path[108];
  };
  LinuxSockAddrUnix guest_addr {};
  guest_addr.family = 1;
  std::strncpy(guest_addr.path, socket_path.c_str(), sizeof(guest_addr.path) - 1);

  FEXCore::HLE::SyscallArguments connect_args {};
  connect_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::connect);
  connect_args.Argument[1] = static_cast<uint64_t>(client_fd);
  connect_args.Argument[2] = reinterpret_cast<uint64_t>(&guest_addr);
  connect_args.Argument[3] = offsetof(LinuxSockAddrUnix, path) + std::strlen(guest_addr.path) + 1;
  require(handler->HandleSyscall(nullptr, &connect_args) == 0, "minimal Darwin syscall handler should translate Linux AF_UNIX connect");

  const int accepted_fd = ::accept(server_fd, nullptr, nullptr);
  require(accepted_fd >= 0, "test should accept translated socket connection");
  ::close(accepted_fd);
  ::close(client_fd);
  ::close(server_fd);
  ::unlink(socket_path.c_str());
}

void test_minimal_darwin_syscall_handler_fails_closed_for_unsupported_syscalls() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  constexpr int linux_enosys = 38;
  FEXCore::HLE::SyscallArguments args {};
  args.Argument[0] = 999999;
  require(
    static_cast<int64_t>(handler->HandleSyscall(nullptr, &args)) == -linux_enosys,
    "minimal Darwin syscall handler should return Linux ENOSYS for unsupported syscalls"
  );

  FEXCore::HLE::SyscallArguments brk_args {};
  brk_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::brk);
  require(handler->HandleSyscall(nullptr, &brk_args) == 0, "minimal Darwin syscall handler should expose a conservative brk base");
}

void test_minimal_darwin_syscall_handler_supports_arch_prctl_tls_base() {
  auto handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler();
  FEXCore::Core::CpuStateFrame frame {};

  constexpr uint64_t arch_set_fs = 0x1002;
  constexpr uint64_t arch_get_fs = 0x1003;
  constexpr uint64_t arch_set_gs = 0x1001;
  constexpr uint64_t arch_get_gs = 0x1004;
  constexpr uint64_t fs_base = 0x12345000;
  constexpr uint64_t gs_base = 0x6789a000;

  FEXCore::HLE::SyscallArguments set_fs_args {};
  set_fs_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::arch_prctl);
  set_fs_args.Argument[1] = arch_set_fs;
  set_fs_args.Argument[2] = fs_base;
  require(
    handler->HandleSyscall(&frame, &set_fs_args) == 0,
    "minimal Darwin syscall handler should accept ARCH_SET_FS"
  );
  require(frame.State.fs_cached == fs_base, "ARCH_SET_FS should update FEX fs base");

  uint64_t observed_fs = 0;
  FEXCore::HLE::SyscallArguments get_fs_args {};
  get_fs_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::arch_prctl);
  get_fs_args.Argument[1] = arch_get_fs;
  get_fs_args.Argument[2] = reinterpret_cast<uint64_t>(&observed_fs);
  require(
    handler->HandleSyscall(&frame, &get_fs_args) == 0,
    "minimal Darwin syscall handler should accept ARCH_GET_FS"
  );
  require(observed_fs == fs_base, "ARCH_GET_FS should report FEX fs base");

  FEXCore::HLE::SyscallArguments set_gs_args {};
  set_gs_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::arch_prctl);
  set_gs_args.Argument[1] = arch_set_gs;
  set_gs_args.Argument[2] = gs_base;
  require(
    handler->HandleSyscall(&frame, &set_gs_args) == 0,
    "minimal Darwin syscall handler should accept ARCH_SET_GS"
  );
  require(frame.State.gs_cached == gs_base, "ARCH_SET_GS should update FEX gs base");

  uint64_t observed_gs = 0;
  FEXCore::HLE::SyscallArguments get_gs_args {};
  get_gs_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::arch_prctl);
  get_gs_args.Argument[1] = arch_get_gs;
  get_gs_args.Argument[2] = reinterpret_cast<uint64_t>(&observed_gs);
  require(
    handler->HandleSyscall(&frame, &get_gs_args) == 0,
    "minimal Darwin syscall handler should accept ARCH_GET_GS"
  );
  require(observed_gs == gs_base, "ARCH_GET_GS should report FEX gs base");

  FEXCore::HLE::SyscallArguments invalid_args {};
  invalid_args.Argument[0] = static_cast<uint64_t>(iridium::fex::ios::MinimalSyscallNumber::arch_prctl);
  invalid_args.Argument[1] = 0xffff;
  require(
    static_cast<int64_t>(handler->HandleSyscall(&frame, &invalid_args)) == -EINVAL,
    "minimal Darwin syscall handler should reject unsupported arch_prctl operations"
  );
}

void test_guest_thread_state_initializes_long_mode_segments() {
  FEXCore::Core::CPUState state {};
  iridium::fex::ios::GuestThreadGDT gdt {};

  iridium::fex::ios::InitializeGuest64BitThreadState(state, gdt);

  require(
    state.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_GDT] == gdt.data(),
    "guest thread state should attach a backed GDT before the decoder reads cs_idx"
  );
  require(
    state.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_LDT] == gdt.data(),
    "guest thread state should mirror LDT to GDT for the minimal in-process launcher"
  );
  require(
    state.cs_idx == FEXCore::Core::CPUState::DEFAULT_USER_CS << 3,
    "guest thread state should use FEX's Linux-compatible default user code selector"
  );

  const auto* code_segment = FEXCore::Core::CPUState::GetSegmentFromIndex(state, state.cs_idx);
  require(code_segment == &gdt[FEXCore::Core::CPUState::DEFAULT_USER_CS], "cs_idx should resolve inside the backed GDT");
  require(code_segment->L == 1, "guest thread state should enter the decoder in 64-bit long mode");
  require(code_segment->D == 0, "64-bit code segment should clear the 32-bit default operand-size flag");
  require(state.cs_cached == FEXCore::Core::CPUState::CalculateGDTBase(*code_segment), "code segment cache should be initialized");
}

void test_guest_thread_runtime_state_initializes_callret_stack() {
  iridium::fex::ios::GuestThreadRuntimeState runtime_state {};
  void* callret_stack_base = nullptr;
  uint64_t callret_sp = 0;

  require(
    iridium::fex::ios::InitializeGuestCallRetStack(callret_stack_base, callret_sp, runtime_state),
    "guest thread runtime state should allocate the call-ret stack required by generated code"
  );

  const auto base = reinterpret_cast<uint64_t>(callret_stack_base);
  require(base != 0, "guest thread runtime state should set the FEX call-ret stack base");
  require(runtime_state.callret_stack_allocation_base != nullptr, "guest thread runtime state should retain the allocation base for cleanup");
  require(
    runtime_state.callret_stack_allocation_size >= iridium::fex::ios::kGuestCallRetStackAllocationSize,
    "guest thread runtime state should include host-page-aligned guard pages around the call-ret stack"
  );
  require(
    callret_sp == base + iridium::fex::ios::kGuestCallRetStackSize / 4,
    "guest thread runtime state should initialize the default call-ret stack pointer"
  );

  iridium::fex::ios::DestroyGuestCallRetStack(callret_stack_base, runtime_state);
  require(callret_stack_base == nullptr, "guest thread runtime cleanup should clear the call-ret stack base");
}

void test_embedded_context_uses_detected_host_features() {
  const auto host_features = iridium::fex::ios::CreateEmbeddedHostFeaturesForFEX();

  require(host_features.DCacheLineSize != 0, "embedded FEX context should use detected D-cache line size");
  require(host_features.ICacheLineSize != 0, "embedded FEX context should use detected I-cache line size");
  require(host_features.SupportsCacheMaintenanceOps, "embedded FEX context should retain detected cache maintenance support");
}

void test_embedded_context_configures_64_bit_guest_mode() {
  FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "0");
  FEXCore::Config::Set(FEXCore::Config::CONFIG_TSOENABLED, "1");
  FEXCore::Config::Set(FEXCore::Config::CONFIG_VECTORTSOENABLED, "1");
  FEXCore::Config::Set(FEXCore::Config::CONFIG_MEMCPYSETTSOENABLED, "1");
  FEXCore::Config::Set(FEXCore::Config::CONFIG_DISABLE_VIXL_INDIRECT_RUNTIME_CALLS, "0");

  iridium::fex::ios::ConfigureEmbeddedFEXFor64BitGuest();

  const auto is_64_bit = FEXCore::Config::GetConv<bool>(FEXCore::Config::CONFIG_IS64BIT_MODE);
  require(
    is_64_bit.value_or(false),
    "embedded FEX context should set IS64BIT_MODE before creating the JIT context for x86-64 Wine"
  );
  const auto tso_enabled = FEXCore::Config::GetConv<bool>(FEXCore::Config::CONFIG_TSOENABLED);
  const auto vector_tso_enabled = FEXCore::Config::GetConv<bool>(FEXCore::Config::CONFIG_VECTORTSOENABLED);
  const auto memcpy_tso_enabled = FEXCore::Config::GetConv<bool>(FEXCore::Config::CONFIG_MEMCPYSETTSOENABLED);
  require(
    !tso_enabled.value_or(true) && !vector_tso_enabled.value_or(true) && !memcpy_tso_enabled.value_or(true),
    "embedded FEX context should disable TSO JIT memory ops until it installs unaligned access handlers"
  );
  const auto direct_runtime_calls = FEXCore::Config::GetConv<bool>(
    FEXCore::Config::CONFIG_DISABLE_VIXL_INDIRECT_RUNTIME_CALLS
  );
  require(
    direct_runtime_calls.value_or(false),
    "embedded FEX context should use direct runtime calls so generated blocks preserve live registers across syscall callbacks"
  );
}
#endif

}  // namespace

int main() {
  try {
    test_probe_readiness_requires_explicit_ready();
    test_probe_readiness_reports_launch_ready_once_jit_is_ready();
    test_probe_readiness_reports_runtime_jit_unavailable();
    test_allocator_probe_can_force_outcomes();
    test_allocator_probe_exercises_real_host_split_allocator_when_enabled();
    test_probe_readiness_reports_real_host_split_allocator_when_enabled();
    test_allocator_probe_fails_closed_under_xcode_debug_environment();
    test_probe_readiness_fails_closed_under_xcode_debug_environment();
    test_allocator_probe_honors_explicit_execution_probe_skip_request();
    test_probe_readiness_reports_trollstore_private_session_kind();
    test_txm_capability_matches_current_stikdebug_device_policy();
    test_probe_readiness_reports_bootstrap_required_metadata();
    test_probe_readiness_requires_helper_bootstrap_before_host_fallback_ready();
    test_helper_bootstrap_command_dispatch_on_host_simulation();
    test_probe_readiness_can_complete_stikdebug_helper_bootstrap();
    test_probe_readiness_requires_translator_artifact();
    test_validate_launch_checks_environment_contract();
    test_validate_launch_reports_specific_missing_executable_status();
    test_validate_launch_reports_specific_missing_prefix_status();
    test_validate_launch_rejects_non_direct_mode();
    test_validate_launch_rejects_non_win64_guest();
    test_validate_launch_accepts_explicit_userland_root_override();
    test_validate_launch_rejects_wine_preloader_without_companion_wine_binary();
    test_start_guest_execution_rejects_non_ready_jit();
    test_start_guest_execution_rejects_runtime_jit_probe_failure();
    test_start_guest_execution_rejects_xcode_debug_launches();
  #if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
    test_guest_loader_maps_loaderless_pie_without_fixed_low_base();
    test_guest_loader_stack_includes_at_random_auxv();
    test_guest_loader_applies_x86_64_tls_relocations();
    test_guest_loader_patches_unresolved_plt_imports_to_trap_stub();
    test_minimal_darwin_syscall_handler_supports_basic_memory_and_write_syscalls();
    test_noreplace_preserves_existing_mapping();
    test_minimal_darwin_syscall_handler_zero_fills_private_file_mappings_past_eof();
    test_minimal_darwin_syscall_handler_accepts_guest_subpage_mprotect();
    test_minimal_darwin_syscall_handler_zero_fills_fixed_anonymous_guest_subpages();
    test_minimal_darwin_syscall_handler_maps_unreserved_fixed_anonymous_guest_subpages();
    test_minimal_darwin_syscall_handler_maps_guest_exec_file_subpages_without_host_exec();
    test_minimal_darwin_syscall_handler_maps_fixed_files_with_guest_aligned_offsets();
    test_minimal_darwin_syscall_handler_supports_preloader_file_and_process_syscalls();
    test_minimal_darwin_syscall_handler_supports_interpreter_file_syscalls();
    test_minimal_darwin_syscall_handler_supports_loader_startup_syscalls();
    test_minimal_darwin_syscall_handler_supports_audited_wine_startup_syscalls();
    test_minimal_darwin_syscall_handler_supports_loader_io_and_identity_syscalls();
    test_minimal_darwin_syscall_handler_supports_linux_stat_syscalls();
    test_minimal_darwin_syscall_handler_supports_linux_getdents64();
    test_minimal_darwin_syscall_handler_supports_futex_wait_and_wake();
    test_minimal_darwin_syscall_handler_supports_cpu_probe_syscalls();
    test_minimal_darwin_syscall_handler_supports_runtime_environment_syscalls();
    test_embedded_wineserver_can_address_registered_guest_threads();
    test_minimal_darwin_syscall_handler_traps_guest_exit_group();
    test_guest_execution_trap_records_fatal_host_signal();
    test_minimal_darwin_syscall_handler_spawns_host_wineserver_helper();
    test_minimal_darwin_syscall_handler_starts_registered_embedded_wineserver();
    test_minimal_darwin_syscall_handler_translates_unix_socket_connect();
    test_minimal_darwin_syscall_handler_fails_closed_for_unsupported_syscalls();
    test_minimal_darwin_syscall_handler_supports_arch_prctl_tls_base();
    test_minimal_darwin_syscall_handler_resolves_absolute_paths_inside_userland_root();
    test_guest_thread_state_initializes_long_mode_segments();
    test_guest_thread_runtime_state_initializes_callret_stack();
    test_embedded_context_uses_detected_host_features();
    test_embedded_context_configures_64_bit_guest_mode();
    test_guest_loader_avoids_overwriting_the_fixed_stack_slot();
  #endif
    test_session_lifecycle_collects_real_terminal_result();
    test_session_lifecycle_does_not_report_running_before_guest_execution();
    test_session_lifecycle_accepts_runtime_session_stop_request();
    test_collect_guest_exit_waits_for_guest_thread_startup();
    test_guest_thread_captures_launch_environment_before_async_startup();
    return 0;
  } catch (const std::exception& error) {
    return fail(error.what());
  }
}
