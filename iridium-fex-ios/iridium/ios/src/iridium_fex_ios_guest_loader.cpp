#include "../include/iridium_fex_ios_guest_loader.h"

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <sys/stat.h>
#include <sys/mman.h>
#include <unistd.h>

#include "../include/iridium_fex_ios_elf_compat.h"

namespace iridium::fex::ios::guest {

namespace {

constexpr uint64_t GUEST_BASE_ADDRESS = 0x0000000000400000ULL;
constexpr uint64_t GUEST_PIE_HINT_ADDRESS = 0x0000000100000000ULL;
constexpr uint64_t GUEST_PAGE_SIZE = 4096;
constexpr uint64_t GUEST_STACK_SIZE = 8ULL * 1024ULL * 1024ULL;
constexpr uint64_t GUEST_STACK_TOP = 0x00007ffffff00000ULL;
constexpr uint64_t GUEST_CANONICAL_USER_TOP = 0x0000800000000000ULL;

struct ELFInfo {
  Elf64_Ehdr ehdr {};
  uint64_t entry_point = 0;
  uint64_t phdr_entry_size = 0;
  uint64_t phdr_count = 0;
  bool has_program_interpreter = false;
  std::string program_interpreter_path;
  std::vector<Elf64_Phdr> program_headers;
};

struct MappedRange {
  uint64_t base = 0;
  uint64_t size = 0;
  uint64_t load_bias = 0;
  struct SegmentPermission {
    uint64_t start = 0;
    uint64_t size = 0;
    uint32_t flags = 0;
  };
  std::vector<SegmentPermission> segment_permissions;
};

struct GuestStackMapping {
  uint64_t base = 0;
  uint64_t top = 0;
  uint64_t size = 0;
};

struct MmapRegionGuard {
  uint64_t base = 0;
  uint64_t size = 0;
  bool active = false;

  ~MmapRegionGuard() {
    if (active && size != 0) {
      munmap(reinterpret_cast<void*>(base), size);
    }
  }

  void release() {
    active = false;
  }
};

uint64_t align_down(uint64_t value, uint64_t alignment) {
  return value & ~(alignment - 1);
}

uint64_t align_up(uint64_t value, uint64_t alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}

uint64_t host_page_size() {
  const long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0) {
    return GUEST_PAGE_SIZE;
  }

  const uint64_t host_page = static_cast<uint64_t>(page_size);
  if ((host_page & (host_page - 1)) != 0) {
    return GUEST_PAGE_SIZE;
  }

  return host_page;
}

uint64_t pie_load_hint(uint64_t min_vaddr, uint64_t alignment) {
  return align_up(std::max(min_vaddr, GUEST_PIE_HINT_ADDRESS), alignment);
}

uint64_t preferred_guest_stack_top() {
  const char* override_value = std::getenv("IRIDIUM_FEX_IOS_TEST_GUEST_STACK_HINT_TOP");
  if (override_value == nullptr || override_value[0] == '\0') {
    return GUEST_STACK_TOP;
  }

  char* end = nullptr;
  errno = 0;
  const unsigned long long parsed = std::strtoull(override_value, &end, 0);
  if (errno != 0 || end == override_value || (end != nullptr && *end != '\0')) {
    return GUEST_STACK_TOP;
  }

  return static_cast<uint64_t>(parsed);
}

int prot_from_elf_flags(uint32_t flags) {
  int prot = 0;
  if ((flags & PF_R) != 0) {
    prot |= PROT_READ;
  }
  if ((flags & PF_W) != 0) {
    prot |= PROT_WRITE;
  }
  return prot;
}

bool checked_add_u64(uint64_t lhs, uint64_t rhs, uint64_t& out) {
  if (rhs > UINT64_MAX - lhs) {
    return false;
  }
  out = lhs + rhs;
  return true;
}

std::optional<GuestStackMapping> allocate_guest_stack(const char* label, std::string& error_message) {
  const uint64_t host_page = host_page_size();
  const uint64_t stack_size = align_up(GUEST_STACK_SIZE, host_page);
  const uint64_t preferred_top = align_down(std::min(preferred_guest_stack_top(), GUEST_CANONICAL_USER_TOP), host_page);

  if (preferred_top < stack_size) {
    error_message = std::string("Configured ") + label + " guest stack top underflows";
    return std::nullopt;
  }

  const uint64_t preferred_base = preferred_top - stack_size;
  void* guest_stack = mmap(
    reinterpret_cast<void*>(preferred_base),
    stack_size,
    PROT_READ | PROT_WRITE,
    MAP_ANONYMOUS | MAP_PRIVATE,
    -1,
    0
  );
  if (guest_stack == MAP_FAILED || guest_stack == nullptr) {
    error_message = std::string("Failed to allocate ") + label + " guest stack: " + std::string(strerror(errno));
    return std::nullopt;
  }

  const uint64_t guest_stack_base = reinterpret_cast<uint64_t>(guest_stack);
  uint64_t guest_stack_top = 0;
  if (!checked_add_u64(guest_stack_base, stack_size, guest_stack_top)) {
    munmap(guest_stack, stack_size);
    error_message = std::string("Allocated ") + label + " guest stack address overflow";
    return std::nullopt;
  }

  if (guest_stack_top > GUEST_CANONICAL_USER_TOP) {
    munmap(guest_stack, stack_size);
    error_message = std::string("Allocated ") + label + " guest stack is outside canonical x86_64 user address space";
    return std::nullopt;
  }

  return GuestStackMapping {
    .base = guest_stack_base,
    .top = guest_stack_top,
    .size = stack_size,
  };
}

bool read_exact(int fd, uint64_t offset, void* buffer, size_t size) {
  auto* out = reinterpret_cast<uint8_t*>(buffer);
  size_t remaining = size;
  while (remaining > 0) {
    const ssize_t bytes = pread(fd, out, remaining, static_cast<off_t>(offset));
    if (bytes <= 0) {
      return false;
    }
    offset += static_cast<uint64_t>(bytes);
    out += bytes;
    remaining -= static_cast<size_t>(bytes);
  }
  return true;
}

bool read_elf_info(int fd, ELFInfo& elf_info, std::string& error_message) {
  if (!read_exact(fd, 0, &elf_info.ehdr, sizeof(elf_info.ehdr))) {
    error_message = "failed to read ELF header";
    return false;
  }

  const auto& ehdr = elf_info.ehdr;
  if (ehdr.e_ident[EI_MAG0] != ELFMAG0 || ehdr.e_ident[EI_MAG1] != ELFMAG1 ||
      ehdr.e_ident[EI_MAG2] != ELFMAG2 || ehdr.e_ident[EI_MAG3] != ELFMAG3) {
    error_message = "invalid ELF magic";
    return false;
  }

  if (ehdr.e_ident[EI_CLASS] != ELFCLASS64 || ehdr.e_ident[EI_DATA] != ELFDATA2LSB ||
      ehdr.e_machine != EM_X86_64) {
    error_message = "unsupported ELF format (expected x86_64 ELF64 LSB)";
    return false;
  }

  if (ehdr.e_phoff == 0 || ehdr.e_phentsize != sizeof(Elf64_Phdr) || ehdr.e_phnum == 0) {
    error_message = "ELF program header table is missing or invalid";
    return false;
  }

  elf_info.program_headers.resize(ehdr.e_phnum);
  if (!read_exact(fd, ehdr.e_phoff, elf_info.program_headers.data(), ehdr.e_phnum * sizeof(Elf64_Phdr))) {
    error_message = "failed to read ELF program headers";
    return false;
  }

  for (const auto& phdr : elf_info.program_headers) {
    if (phdr.p_type == PT_INTERP && phdr.p_filesz > 0) {
      elf_info.has_program_interpreter = true;
      std::vector<char> interpreter(static_cast<size_t>(phdr.p_filesz));
      if (!read_exact(fd, phdr.p_offset, interpreter.data(), interpreter.size())) {
        error_message = "failed to read ELF program interpreter";
        return false;
      }
      const auto terminator = std::find(interpreter.begin(), interpreter.end(), '\0');
      elf_info.program_interpreter_path.assign(interpreter.begin(), terminator);
      break;
    }
  }

  elf_info.entry_point = ehdr.e_entry;
  elf_info.phdr_entry_size = ehdr.e_phentsize;
  elf_info.phdr_count = ehdr.e_phnum;
  return true;
}

std::optional<MappedRange> map_elf_segments(int fd, const ELFInfo& info, std::string& error_message) {
  struct stat file_stat {};
  if (fstat(fd, &file_stat) != 0 || file_stat.st_size < 0) {
    error_message = "failed to stat guest ELF file";
    return std::nullopt;
  }
  const uint64_t file_size = static_cast<uint64_t>(file_stat.st_size);
  const uint64_t host_page = host_page_size();

  bool have_load = false;
  uint64_t min_vaddr = UINT64_MAX;
  uint64_t max_vaddr = 0;
  std::vector<std::pair<uint64_t, uint64_t>> load_ranges;

  for (const auto& phdr : info.program_headers) {
    if (phdr.p_type != PT_LOAD || phdr.p_memsz == 0) {
      continue;
    }

    if (phdr.p_filesz > phdr.p_memsz) {
      error_message = "PT_LOAD segment has p_filesz > p_memsz";
      return std::nullopt;
    }

    uint64_t file_limit = 0;
    if (!checked_add_u64(phdr.p_offset, phdr.p_filesz, file_limit) || file_limit > file_size) {
      error_message = "PT_LOAD segment file region exceeds ELF file size";
      return std::nullopt;
    }

    uint64_t seg_end_raw = 0;
    if (!checked_add_u64(phdr.p_vaddr, phdr.p_memsz, seg_end_raw)) {
      error_message = "PT_LOAD segment address overflow";
      return std::nullopt;
    }

    have_load = true;
    min_vaddr = std::min(min_vaddr, phdr.p_vaddr);
    max_vaddr = std::max(max_vaddr, seg_end_raw);
    load_ranges.push_back({phdr.p_vaddr, seg_end_raw});
  }

  std::sort(load_ranges.begin(), load_ranges.end());
  for (size_t i = 1; i < load_ranges.size(); ++i) {
    if (load_ranges[i - 1].second > load_ranges[i].first) {
      error_message = "PT_LOAD segments overlap in virtual address space";
      return std::nullopt;
    }
  }

  if (!have_load || min_vaddr >= max_vaddr) {
    error_message = "ELF has no loadable PT_LOAD segments";
    return std::nullopt;
  }

  const bool is_pie = info.ehdr.e_type == ET_DYN;
  uint64_t reserve_base = 0;
  uint64_t reserve_size = 0;
  uint64_t load_bias = 0;

  if (is_pie) {
    reserve_size = align_up(max_vaddr - min_vaddr, host_page);
    void* reservation = mmap(
      reinterpret_cast<void*>(pie_load_hint(min_vaddr, host_page)),
      reserve_size,
      PROT_NONE,
      MAP_PRIVATE | MAP_ANONYMOUS,
      -1,
      0
    );
    if (reservation == MAP_FAILED) {
      error_message = "failed to reserve guest address space: " + std::string(strerror(errno));
      return std::nullopt;
    }

    reserve_base = reinterpret_cast<uint64_t>(reservation);
    if (reserve_base < min_vaddr) {
      munmap(reservation, reserve_size);
      error_message = "guest PIE reservation base underflow";
      return std::nullopt;
    }

    load_bias = reserve_base - min_vaddr;
  } else {
    reserve_base = align_down(min_vaddr, host_page);
    const uint64_t reserve_limit = align_up(max_vaddr, host_page);
    reserve_size = reserve_limit - reserve_base;

    void* reservation = mmap(
      reinterpret_cast<void*>(reserve_base),
      reserve_size,
      PROT_NONE,
      MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
      -1,
      0
    );
    if (reservation == MAP_FAILED) {
      error_message = "failed to reserve guest address space: " + std::string(strerror(errno));
      return std::nullopt;
    }
  }

  MmapRegionGuard reservation_guard {
    .base = reserve_base,
    .size = reserve_size,
    .active = true,
  };

  std::map<uint64_t, uint32_t> page_permissions;

  for (const auto& phdr : info.program_headers) {
    if (phdr.p_type != PT_LOAD || phdr.p_memsz == 0) {
      continue;
    }

    uint64_t seg_vaddr = 0;
    uint64_t seg_limit = 0;
    if (!checked_add_u64(phdr.p_vaddr, load_bias, seg_vaddr) ||
        !checked_add_u64(seg_vaddr, phdr.p_memsz, seg_limit)) {
      error_message = "PT_LOAD mapping address overflow";
      return std::nullopt;
    }

    const uint64_t seg_start = align_down(seg_vaddr, host_page);
    const uint64_t seg_end = align_up(seg_limit, host_page);
    const uint64_t seg_size = seg_end - seg_start;
    const uint64_t load_addr = seg_vaddr;

    if (mprotect(reinterpret_cast<void*>(seg_start), seg_size, PROT_READ | PROT_WRITE) != 0) {
      error_message = "failed to set temporary segment permissions: " + std::string(strerror(errno));
      return std::nullopt;
    }

    if (phdr.p_filesz > 0) {
      if (!read_exact(fd, phdr.p_offset, reinterpret_cast<void*>(load_addr), phdr.p_filesz)) {
        error_message = "failed to read PT_LOAD file bytes";
        return std::nullopt;
      }
    }

    if (phdr.p_memsz > phdr.p_filesz) {
      std::memset(
        reinterpret_cast<void*>(load_addr + phdr.p_filesz),
        0,
        static_cast<size_t>(phdr.p_memsz - phdr.p_filesz)
      );
    }

    for (uint64_t page = seg_start; page < seg_end; page += host_page) {
      page_permissions[page] |= phdr.p_flags;
    }
  }

  MappedRange result {
    .base = reserve_base,
    .size = reserve_size,
    .load_bias = load_bias,
  };

  for (const auto& [page_start, flags] : page_permissions) {
    if (!result.segment_permissions.empty()) {
      auto& last = result.segment_permissions.back();
      if (last.start + last.size == page_start && last.flags == flags) {
        last.size += host_page;
        continue;
      }
    }

    result.segment_permissions.push_back(
      MappedRange::SegmentPermission {
        .start = page_start,
        .size = host_page,
        .flags = flags,
      }
    );
  }

  reservation_guard.release();
  return result;
}

bool apply_dynamic_relocations(const ELFInfo& info, uint64_t load_bias, std::string& error_message) {
  const Elf64_Phdr* dynamic_phdr = nullptr;
  const Elf64_Phdr* tls_phdr = nullptr;
  for (const auto& phdr : info.program_headers) {
    if (phdr.p_type == PT_DYNAMIC && phdr.p_memsz >= sizeof(Elf64_Dyn)) {
      dynamic_phdr = &phdr;
    } else if (phdr.p_type == PT_TLS && phdr.p_memsz != 0) {
      tls_phdr = &phdr;
    }
  }

  if (dynamic_phdr == nullptr) {
    return true;
  }

  const auto* dynamic_table = reinterpret_cast<const Elf64_Dyn*>(dynamic_phdr->p_vaddr + load_bias);
  const size_t dynamic_count = dynamic_phdr->p_memsz / sizeof(Elf64_Dyn);

  uint64_t rela_table = 0;
  uint64_t rela_size = 0;
  uint64_t rela_ent = sizeof(Elf64_Rela);
  uint64_t rel_table = 0;
  uint64_t rel_size = 0;
  uint64_t rel_ent = sizeof(Elf64_Rel);
  uint64_t sym_table = 0;
  uint64_t sym_ent = sizeof(Elf64_Sym);
  uint64_t str_table = 0;
  uint64_t str_size = 0;
  uint64_t jmprel_table = 0;
  uint64_t pltrel_size = 0;
  uint64_t pltrel_type = DT_RELA;

  for (size_t i = 0; i < dynamic_count; ++i) {
    const auto& dyn = dynamic_table[i];
    switch (dyn.d_tag) {
      case DT_NULL:
        i = dynamic_count;
        break;
      case DT_RELA:
        rela_table = dyn.d_un.d_ptr + load_bias;
        break;
      case DT_RELASZ:
        rela_size = dyn.d_un.d_val;
        break;
      case DT_RELAENT:
        rela_ent = dyn.d_un.d_val;
        break;
      case DT_REL:
        rel_table = dyn.d_un.d_ptr + load_bias;
        break;
      case DT_RELSZ:
        rel_size = dyn.d_un.d_val;
        break;
      case DT_RELENT:
        rel_ent = dyn.d_un.d_val;
        break;
      case DT_SYMTAB:
        sym_table = dyn.d_un.d_ptr + load_bias;
        break;
      case DT_SYMENT:
        sym_ent = dyn.d_un.d_val;
        break;
        case DT_STRTAB:
          str_table = dyn.d_un.d_ptr + load_bias;
          break;
        case DT_STRSZ:
          str_size = dyn.d_un.d_val;
          break;
        case DT_JMPREL:
          jmprel_table = dyn.d_un.d_ptr + load_bias;
          break;
        case DT_PLTRELSZ:
          pltrel_size = dyn.d_un.d_val;
          break;
        case DT_PLTREL:
          pltrel_type = dyn.d_un.d_val;
          break;
      default:
        break;
    }
  }

  if (rela_size > 0 && rela_table == 0) {
    error_message = "DT_RELASZ present without DT_RELA";
    return false;
  }
  if (rel_size > 0 && rel_table == 0) {
    error_message = "DT_RELSZ present without DT_REL";
    return false;
  }
  if (sym_ent == 0 || sym_ent < sizeof(Elf64_Sym)) {
    error_message = "invalid DT_SYMENT value";
    return false;
  }

    if (pltrel_size > 0 && jmprel_table == 0) {
      error_message = "DT_PLTRELSZ present without DT_JMPREL";
      return false;
    }
    if (pltrel_size > 0 && pltrel_type != DT_RELA && pltrel_type != DT_REL) {
      error_message = "unsupported DT_PLTREL value";
      return false;
    }

  auto symbol_name = [&](const Elf64_Sym* sym) -> std::string {
    if (sym != nullptr && str_table != 0 && str_size != 0 && sym->st_name < str_size) {
      const auto* strtab = reinterpret_cast<const char*>(str_table);
      return std::string(strtab + sym->st_name);
    }
    return "<unknown>";
  };

  auto unresolved_plt_trap_stub_address = [&]() -> uint64_t {
    static const uint64_t trap_stub = []() -> uint64_t {
      constexpr uint8_t ud2[] = {0x0f, 0x0b};
      const uint64_t host_page = host_page_size();
      void* page = mmap(
        nullptr,
        host_page,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS,
        -1,
        0
      );
      if (page == MAP_FAILED || page == nullptr) {
        return 0;
      }
      std::memcpy(page, ud2, sizeof(ud2));
      if (mprotect(page, host_page, PROT_READ) != 0) {
        munmap(page, host_page);
        return 0;
      }
      return reinterpret_cast<uint64_t>(page);
    }();
    return trap_stub;
  };

  auto resolve_symbol = [&](uint32_t sym_index, bool allow_unresolved_plt_stub, uint64_t& resolved) -> bool {
    if (sym_index == 0) {
      resolved = 0;
      return true;
    }
    if (sym_table == 0) {
      error_message = "symbol relocation requires DT_SYMTAB";
      return false;
    }

    const auto* sym = reinterpret_cast<const Elf64_Sym*>(sym_table + static_cast<uint64_t>(sym_index) * sym_ent);
    if (sym->st_shndx == SHN_UNDEF) {
      if (ELF64_ST_BIND(sym->st_info) == STB_WEAK) {
        resolved = 0;
        return true;
      }

      if (allow_unresolved_plt_stub) {
        resolved = unresolved_plt_trap_stub_address();
        if (resolved != 0) {
          return true;
        }
        error_message = "could not allocate unresolved PLT trap stub for symbol: " + symbol_name(sym);
        return false;
      }

      error_message = "encountered unresolved external symbol relocation: " + symbol_name(sym);
      return false;
    }

    resolved = load_bias + sym->st_value;
    return true;
  };

  auto resolve_tls_symbol_offset = [&](uint32_t sym_index, int64_t addend, uint64_t& resolved) -> bool {
    if (sym_index == 0) {
      if (tls_phdr == nullptr) {
        error_message = "TLS relocation requires PT_TLS";
        return false;
      }
      const uint64_t tls_base = tls_phdr->p_paddr != 0 ? tls_phdr->p_paddr : tls_phdr->p_vaddr;
      resolved = tls_base + static_cast<uint64_t>(addend);
      return true;
    }

    if (sym_table == 0) {
      error_message = "TLS symbol relocation requires DT_SYMTAB";
      return false;
    }

    const auto* sym = reinterpret_cast<const Elf64_Sym*>(sym_table + static_cast<uint64_t>(sym_index) * sym_ent);
    resolved = sym->st_value + static_cast<uint64_t>(addend);
    return true;
  };

  auto apply_reloc = [&](uint32_t type, uint32_t sym_index, int64_t addend, uint64_t target_addr) -> bool {
    auto* target = reinterpret_cast<uint64_t*>(target_addr);
    switch (type) {
      case R_X86_64_NONE:
        return true;
      case R_X86_64_RELATIVE:
        *target = load_bias + static_cast<uint64_t>(addend);
        return true;
      case R_X86_64_64:
      case R_X86_64_GLOB_DAT: {
        uint64_t symbol_value = 0;
        if (!resolve_symbol(sym_index, false, symbol_value)) {
          return false;
        }
        *target = symbol_value + static_cast<uint64_t>(addend);
        return true;
      }
      case R_X86_64_JUMP_SLOT: {
        uint64_t symbol_value = 0;
        if (!resolve_symbol(sym_index, true, symbol_value)) {
          return false;
        }
        *target = symbol_value + static_cast<uint64_t>(addend);
        return true;
      }
      case R_X86_64_DTPMOD64:
        *target = 0;
        return true;
      case R_X86_64_DTPOFF64:
      case R_X86_64_TPOFF64: {
        uint64_t tls_offset = 0;
        if (!resolve_tls_symbol_offset(sym_index, addend, tls_offset)) {
          return false;
        }
        *target = tls_offset;
        return true;
      }
      default:
        error_message = "unsupported relocation type: " + std::to_string(type);
        return false;
    }
  };

    auto apply_rela_table = [&](uint64_t table_address, uint64_t table_size, uint64_t entry_size) -> bool {
      if (table_size == 0) {
        return true;
      }
      if (entry_size == 0 || table_size % entry_size != 0 || entry_size < sizeof(Elf64_Rela)) {
        error_message = "invalid RELA table shape";
        return false;
      }

      const size_t count = static_cast<size_t>(table_size / entry_size);
      for (size_t i = 0; i < count; ++i) {
        const auto* rela = reinterpret_cast<const Elf64_Rela*>(table_address + static_cast<uint64_t>(i) * entry_size);
        const uint32_t type = ELF64_R_TYPE(rela->r_info);
        const uint32_t sym = ELF64_R_SYM(rela->r_info);
        uint64_t target_addr = 0;
        if (!checked_add_u64(load_bias, rela->r_offset, target_addr)) {
          error_message = "relocation target address overflow";
          return false;
        }
        if (!apply_reloc(type, sym, rela->r_addend, target_addr)) {
          return false;
        }
      }

      return true;
    };

    auto apply_rel_table = [&](uint64_t table_address, uint64_t table_size, uint64_t entry_size) -> bool {
      if (table_size == 0) {
        return true;
      }
      if (entry_size == 0 || table_size % entry_size != 0 || entry_size < sizeof(Elf64_Rel)) {
        error_message = "invalid REL table shape";
        return false;
      }

      const size_t count = static_cast<size_t>(table_size / entry_size);
      for (size_t i = 0; i < count; ++i) {
        const auto* rel = reinterpret_cast<const Elf64_Rel*>(table_address + static_cast<uint64_t>(i) * entry_size);
        const uint32_t type = ELF64_R_TYPE(rel->r_info);
        const uint32_t sym = ELF64_R_SYM(rel->r_info);
        uint64_t target_addr = 0;
        if (!checked_add_u64(load_bias, rel->r_offset, target_addr)) {
          error_message = "relocation target address overflow";
          return false;
        }
        const int64_t addend = static_cast<int64_t>(*reinterpret_cast<uint64_t*>(target_addr));
        if (!apply_reloc(type, sym, addend, target_addr)) {
          return false;
        }
      }

      return true;
    };

    if (!apply_rela_table(rela_table, rela_size, rela_ent)) {
      return false;
  }

    if (!apply_rel_table(rel_table, rel_size, rel_ent)) {
      return false;
    }

    if (pltrel_size > 0) {
      if (pltrel_type == DT_RELA) {
        if (!apply_rela_table(jmprel_table, pltrel_size, rela_ent)) {
          return false;
        }
      } else {
        if (!apply_rel_table(jmprel_table, pltrel_size, rel_ent)) {
          return false;
        }
      }
  }

  return true;
}

bool finalize_segment_permissions(const MappedRange& mapped_range, std::string& error_message) {
  for (const auto& permission : mapped_range.segment_permissions) {
    int prot = prot_from_elf_flags(permission.flags);
    if (prot == 0) {
      prot = PROT_NONE;
    }
    if (mprotect(reinterpret_cast<void*>(permission.start), permission.size, prot) != 0) {
      error_message = "failed to set final segment permissions: " + std::string(strerror(errno));
      return false;
    }
  }
  return true;
}

std::optional<uint64_t> program_header_address(const ELFInfo& elf_info, const MappedRange& mapped_range) {
  const uint64_t load_bias = mapped_range.load_bias;
  for (const auto& phdr : elf_info.program_headers) {
    if (phdr.p_type == PT_PHDR) {
      return phdr.p_vaddr + load_bias;
    }
  }

  for (const auto& phdr : elf_info.program_headers) {
    if (phdr.p_type != PT_LOAD) {
      continue;
    }
    const uint64_t hdr_offset = elf_info.ehdr.e_phoff;
    if (hdr_offset >= phdr.p_offset && hdr_offset < phdr.p_offset + phdr.p_memsz) {
      return (hdr_offset - phdr.p_offset) + phdr.p_vaddr + load_bias;
    }
  }

  uint64_t fallback_phdr = 0;
  if (checked_add_u64(load_bias, elf_info.ehdr.e_phoff, fallback_phdr)) {
    const uint64_t mapped_start = mapped_range.base;
    const uint64_t mapped_end = mapped_range.base + mapped_range.size;
    if (fallback_phdr >= mapped_start &&
        fallback_phdr + (elf_info.phdr_count * elf_info.phdr_entry_size) <= mapped_end) {
      return fallback_phdr;
    }
  }

  return std::nullopt;
}

std::string resolve_guest_interpreter_path(const std::string& interpreter_path) {
  if (interpreter_path.empty() || interpreter_path.front() != '/') {
    return interpreter_path;
  }

  const char* userland_root = std::getenv("IRIDIUM_USERLAND_ROOT");
  if (userland_root == nullptr || userland_root[0] == '\0') {
    return interpreter_path;
  }

  std::string resolved = userland_root;
  if (!resolved.empty() && resolved.back() == '/') {
    resolved.pop_back();
  }
  resolved += interpreter_path;
  return resolved;
}

}  // namespace

LoaderResult GuestBinaryLoader::LoadAndInitializeGuest(
  const std::string& wine_binary_path,
  FEXCore::Context::Context* context,
  const std::vector<std::string>& guest_args,
  const std::vector<std::string>& guest_environment
) {
  LoaderResult result;

  if (!context) {
    result.error_message = "Invalid context";
    return result;
  }

  (void)context;

  const char* smoke_guest_image = std::getenv("IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE");
  if (smoke_guest_image != nullptr && std::string(smoke_guest_image) == "1") {
    const uint64_t host_page = host_page_size();
    void* guest_code = mmap(
      reinterpret_cast<void*>(GUEST_BASE_ADDRESS),
      host_page,
      PROT_READ | PROT_WRITE | PROT_EXEC,
      MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
      -1,
      0
    );
    if (guest_code == MAP_FAILED || guest_code == nullptr) {
      result.error_message = "Failed to allocate smoke guest code page";
      return result;
    }

    MmapRegionGuard guest_code_guard {
      .base = GUEST_BASE_ADDRESS,
      .size = host_page,
      .active = true,
    };

    // x86_64 RET for deterministic thread bootstrap smoke checks.
    *reinterpret_cast<uint8_t*>(guest_code) = 0xC3;
    if (mprotect(guest_code, host_page, PROT_READ | PROT_EXEC) != 0) {
      result.error_message = "Failed to finalize smoke guest code permissions";
      return result;
    }

    const auto guest_stack_mapping = allocate_guest_stack("smoke", result.error_message);
    if (!guest_stack_mapping.has_value()) {
      return result;
    }

    MmapRegionGuard guest_stack_guard {
      .base = guest_stack_mapping->base,
      .size = guest_stack_mapping->size,
      .active = true,
    };

    const uint64_t entrypoint = GUEST_BASE_ADDRESS;
    const uint64_t stack_pointer = SetupGuestStack(
      guest_stack_mapping->top,
      entrypoint,
      0,
      0,
      0,
      0,
      guest_args,
      guest_environment
    );
    if (stack_pointer == 0) {
      result.error_message = "Failed to construct smoke guest stack image";
      return result;
    }

    guest_code_guard.release();
    guest_stack_guard.release();

    result.success = true;
    result.entrypoint = entrypoint;
    result.stack_address = stack_pointer;
    result.load_base = GUEST_BASE_ADDRESS;
    result.mapped_size = host_page;
    return result;
  }

  int fd = open(wine_binary_path.c_str(), O_RDONLY);
  if (fd < 0) {
    result.error_message = "Cannot open Wine binary: " + std::string(strerror(errno));
    return result;
  }
  
  struct FDGuard {
    int fd;
    ~FDGuard() { if (fd >= 0) close(fd); }
  } fd_guard{fd};

  ELFInfo elf_info;
  if (!read_elf_info(fd, elf_info, result.error_message)) {
    return result;
  }

  const auto mapped_range = map_elf_segments(fd, elf_info, result.error_message);
  if (!mapped_range.has_value()) {
    return result;
  }

  MmapRegionGuard mapped_guard {
    .base = mapped_range->base,
    .size = mapped_range->size,
    .active = true,
  };

  if (!elf_info.has_program_interpreter &&
      !apply_dynamic_relocations(elf_info, mapped_range->load_bias, result.error_message)) {
    return result;
  }

  if (!finalize_segment_permissions(*mapped_range, result.error_message)) {
    return result;
  }

  const uint64_t load_bias = mapped_range->load_bias;
  const auto phdr_address_value = program_header_address(elf_info, *mapped_range);
  if (!phdr_address_value.has_value()) {
    result.error_message = "Failed to determine a valid ELF program-header address for AUXV (AT_PHDR)";
    return result;
  }
  const uint64_t phdr_address = *phdr_address_value;

  const uint64_t main_entrypoint = elf_info.entry_point + load_bias;
  uint64_t entrypoint = main_entrypoint;
  uint64_t interpreter_base = 0;
  std::optional<MappedRange> interpreter_mapped_range;
  MmapRegionGuard interpreter_guard {};

  if (elf_info.has_program_interpreter) {
    const std::string interpreter_path = resolve_guest_interpreter_path(elf_info.program_interpreter_path);
    int interpreter_fd = open(interpreter_path.c_str(), O_RDONLY);
    if (interpreter_fd < 0) {
      result.error_message = "Cannot open ELF program interpreter " + elf_info.program_interpreter_path + ": " + std::string(strerror(errno));
      return result;
    }

    FDGuard interpreter_fd_guard{interpreter_fd};
    ELFInfo interpreter_info;
    if (!read_elf_info(interpreter_fd, interpreter_info, result.error_message)) {
      result.error_message = "Program interpreter ELF is invalid: " + result.error_message;
      return result;
    }
    if (interpreter_info.has_program_interpreter) {
      result.error_message = "Program interpreter unexpectedly has its own PT_INTERP";
      return result;
    }

    interpreter_mapped_range = map_elf_segments(interpreter_fd, interpreter_info, result.error_message);
    if (!interpreter_mapped_range.has_value()) {
      return result;
    }

    interpreter_guard.base = interpreter_mapped_range->base;
    interpreter_guard.size = interpreter_mapped_range->size;
    interpreter_guard.active = true;

    if (!finalize_segment_permissions(*interpreter_mapped_range, result.error_message)) {
      return result;
    }

    interpreter_base = interpreter_mapped_range->base;
    entrypoint = interpreter_info.entry_point + interpreter_mapped_range->load_bias;
  }

  const char* skip_stack_setup = std::getenv("IRIDIUM_FEX_IOS_TEST_SKIP_GUEST_STACK_SETUP");
  if (skip_stack_setup != nullptr && std::string(skip_stack_setup) == "1") {
    mapped_guard.release();
    interpreter_guard.release();

    result.success = true;
    result.entrypoint = entrypoint;
    result.load_base = mapped_range->base;
    result.mapped_size = mapped_range->size;
    result.phdr_address = phdr_address;
    result.phdr_entry_size = elf_info.phdr_entry_size;
    result.phdr_count = elf_info.phdr_count;
    return result;
  }

  const auto guest_stack_mapping = allocate_guest_stack("guest", result.error_message);
  if (!guest_stack_mapping.has_value()) {
    return result;
  }

  MmapRegionGuard guest_stack_guard {
    .base = guest_stack_mapping->base,
    .size = guest_stack_mapping->size,
    .active = true,
  };

  const uint64_t stack_pointer = SetupGuestStack(
    guest_stack_mapping->top,
    main_entrypoint,
    phdr_address,
    elf_info.phdr_entry_size,
    elf_info.phdr_count,
    interpreter_base,
    guest_args,
    guest_environment
  );
  if (stack_pointer == 0) {
    result.error_message = "Failed to construct guest stack image";
    return result;
  }

  mapped_guard.release();
  interpreter_guard.release();
  guest_stack_guard.release();

  result.success = true;
  result.entrypoint = entrypoint;
  result.stack_address = stack_pointer;
  result.load_base = mapped_range->base;
  result.mapped_size = mapped_range->size;
  result.phdr_address = phdr_address;
  result.phdr_entry_size = elf_info.phdr_entry_size;
  result.phdr_count = elf_info.phdr_count;
  return result;
}

uint64_t GuestBinaryLoader::SetupGuestStack(
  uint64_t stack_top,
  uint64_t entrypoint,
  uint64_t phdr_address,
  uint64_t phdr_entry_size,
  uint64_t phdr_count,
  uint64_t interpreter_base,
  const std::vector<std::string>& args,
  const std::vector<std::string>& environment
) {
  uint64_t sp = align_down(stack_top, 16);
  const uint64_t stack_low = stack_top - GUEST_STACK_SIZE;

  auto push_bytes = [&](const void* src, size_t size) -> std::optional<uint64_t> {
    if (size == 0) {
      return sp;
    }
    if (sp < stack_low + size) {
      return std::nullopt;
    }
    sp -= size;
    std::memcpy(reinterpret_cast<void*>(sp), src, size);
    return sp;
  };

  auto push_u64 = [&](uint64_t value) -> bool {
    if (sp < stack_low + sizeof(uint64_t)) {
      return false;
    }
    sp -= sizeof(uint64_t);
    *reinterpret_cast<uint64_t*>(sp) = value;
    return true;
  };

  std::vector<uint64_t> arg_ptrs;
  arg_ptrs.reserve(args.size());
  for (auto it = args.rbegin(); it != args.rend(); ++it) {
    const auto ptr = push_bytes(it->c_str(), it->size() + 1);
    if (!ptr.has_value()) {
      return 0;
    }
    arg_ptrs.push_back(*ptr);
  }
  std::reverse(arg_ptrs.begin(), arg_ptrs.end());

  std::vector<uint64_t> env_ptrs;
  env_ptrs.reserve(environment.size());
  for (auto it = environment.rbegin(); it != environment.rend(); ++it) {
    const auto ptr = push_bytes(it->c_str(), it->size() + 1);
    if (!ptr.has_value()) {
      return 0;
    }
    env_ptrs.push_back(*ptr);
  }
  std::reverse(env_ptrs.begin(), env_ptrs.end());

  constexpr std::array<uint8_t, 16> kGuestRandomSeed = {{
    0x69, 0x72, 0x69, 0x64, 0x69, 0x75, 0x6d, 0x2d,
    0x66, 0x65, 0x78, 0x2d, 0x61, 0x75, 0x78, 0x76,
  }};
  const auto random_seed_ptr = push_bytes(kGuestRandomSeed.data(), kGuestRandomSeed.size());
  if (!random_seed_ptr.has_value()) {
    return 0;
  }

  sp = align_down(sp, 16);

  struct AuxEntry {
    uint64_t key;
    uint64_t value;
  };
  const std::array<AuxEntry, 8> aux_entries = {{
    {AT_PAGESZ, GUEST_PAGE_SIZE},
    {AT_PHDR, phdr_address},
    {AT_PHENT, phdr_entry_size},
    {AT_PHNUM, phdr_count},
    {AT_BASE, interpreter_base},
    {AT_ENTRY, entrypoint},
    {AT_RANDOM, *random_seed_ptr},
    {AT_NULL, 0},
  }};

  for (auto it = aux_entries.rbegin(); it != aux_entries.rend(); ++it) {
    if (!push_u64(it->value) || !push_u64(it->key)) {
      return 0;
    }
  }

  if (!push_u64(0)) {
    return 0;
  }
  for (auto it = env_ptrs.rbegin(); it != env_ptrs.rend(); ++it) {
    if (!push_u64(*it)) {
      return 0;
    }
  }

  if (!push_u64(0)) {
    return 0;
  }
  for (auto it = arg_ptrs.rbegin(); it != arg_ptrs.rend(); ++it) {
    if (!push_u64(*it)) {
      return 0;
    }
  }

  if (!push_u64(args.size())) {
    return 0;
  }

  return sp;
}

}  // namespace iridium::fex::ios::guest

#endif  // IRIDIUM_FEX_IOS_ENABLE_FEXCORE
