"""Azahar-only source overlays and dependency checks for the shared builder."""
import engine_pins
import hashlib
import importlib.util
import json
import shutil
import tarfile
from pathlib import Path


def source_archive():
    return engine_pins.get('azahar')['artifacts']['source']['filename']


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def moltenvk(ROOT, sdk, jobs=None):
    pin = engine_pins.get('azahar')['buildDependencies']['moltenVK']
    manifest = ROOT / pin['inputs']
    spec = importlib.util.spec_from_file_location('azahar_moltenvk', ROOT / 'ci/build-ppsspp-moltenvk.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    directory = ROOT / '.build/azahar/moltenvk-derived' / ('package-' + sdk)
    library = directory / 'Build/Products' / ('Release-' + sdk) / 'libMoltenVK.a'
    receipt = directory / 'component.json'
    if jobs is not None and not receipt.is_file():
        return module.build(sdk, jobs, inputs=manifest, version=pin['version'], build_root=ROOT / '.build/azahar')
    record = json.loads(receipt.read_text())
    if record.get('version') != pin['version'] or record.get('sourceInputs') != json.loads(manifest.read_text()) or record.get('sourceArchiveSHA256') != digest(manifest) or record.get('archiveSHA256') != digest(library):
        raise ValueError('Azahar MoltenVK receipt differs from its pinned inputs')
    for item in record['sourceInputs']:
        archive = ROOT / '.build/runtime-downloads' / (item['sha256'] + '.tar')
        if digest(archive) != item['sha256'] or module.verify_tree(archive, ROOT / '.build/azahar/moltenvk-source' / item['name']) != record['sourceTreeSHA256'][item['name']]:
            raise ValueError('Azahar MoltenVK source changed: ' + item['name'])
    return library, record


def generated(ROOT, directory):
    source = ROOT / '.build/phase3-downloads' / source_archive().removesuffix('.tar.xz')
    (directory / 'am.cpp').unlink(missing_ok=True)
    def replace(text, old, new, count=1):
        if text.count(old) != count:
            raise ValueError('Azahar shared JIT source hook changed: ' + old)
        return text.replace(old, new)
    oaknut = source / 'externals/dynarmic/externals/oaknut/include/oaknut/code_block.hpp'
    code = oaknut.read_text()
    code = replace(code, 'namespace oaknut {', 'extern "C" void* ir_azahar_jit_allocate(std::size_t, void**);\nextern "C" void ir_azahar_jit_release(void*, void*, std::size_t);\n\nnamespace oaknut {')
    code = replace(code, '#    if TARGET_OS_IPHONE\n        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);',
        '#    if TARGET_OS_IPHONE\n        void* writable = nullptr;\n        m_memory = static_cast<std::uint32_t*>(ir_azahar_jit_allocate(size, &writable));\n        m_wmemory = static_cast<std::uint32_t*>(writable);')
    code = replace(code, '        munmap(m_memory, m_size);', '#if defined(__APPLE__) && TARGET_OS_IPHONE\n        ir_azahar_jit_release(m_memory, m_wmemory, m_size);\n#else\n        munmap(m_memory, m_size);\n#endif')
    code = replace(code, '    void protect()', '    std::uint32_t* wptr() const\n    {\n#if defined(__APPLE__) && TARGET_OS_IPHONE\n        return m_wmemory;\n#else\n        return m_memory;\n#endif\n    }\n\n    void protect()')
    # iOS keeps separate RW and RX aliases, so generated code stays executable.
    code = replace(code, '#elif defined(__APPLE__) || defined(__NetBSD__) || defined(__OpenBSD__)', '#elif (defined(__APPLE__) && !TARGET_OS_IPHONE) || defined(__NetBSD__) || defined(__OpenBSD__)', 2)
    code = replace(code, '        sys_icache_invalidate(mem, size);', '#if TARGET_OS_IPHONE\n        sys_dcache_flush(m_wmemory + (mem - m_memory), size);\n#endif\n        sys_icache_invalidate(mem, size);')
    code = replace(code, '    std::uint32_t* m_memory;', '    std::uint32_t* m_memory;\n    std::uint32_t* m_wmemory = nullptr;')
    header = directory / 'include/oaknut/code_block.hpp'
    header.parent.mkdir(parents=True, exist_ok=True); header.write_text(code)
    arm = source / 'externals/dynarmic/src/dynarmic/backend/arm64/address_space.cpp'
    code = replace(arm.read_text(), 'code(mem.ptr(), mem.ptr())', 'code(mem.wptr(), mem.ptr())')
    code = replace(code, 'CodeGenerator c{mem.ptr(), mem.ptr()};', 'CodeGenerator c{mem.wptr(), mem.ptr()};', 2)
    (directory / 'address_space.cpp').write_text(code)
    spin = source / 'externals/dynarmic/src/dynarmic/common/spin_lock_arm64.cpp'
    code = replace(spin.read_text(), 'SpinLockImpl impl;', 'SpinLockImpl& GetImpl() {\n    static SpinLockImpl impl;\n    return impl;\n}')
    code = replace(code, 'code{mem.ptr(), mem.ptr()}', 'code{mem.wptr(), mem.ptr()}')
    code = replace(code, '    std::call_once(flag, &SpinLockImpl::Initialize, impl);', '    auto& impl = GetImpl();\n    std::call_once(flag, &SpinLockImpl::Initialize, impl);', 2)
    (directory / spin.name).write_text(code)
    shader = source / 'src/video_core/shader/shader_jit_a64_compiler.cpp'
    code = replace(shader.read_text(), 'std::memcpy(code_mem->ptr(), code_vec.data(), code_vec.size() * sizeof(u32));', 'std::memcpy(code_mem->wptr(), code_vec.data(), code_vec.size() * sizeof(u32));')
    (directory / shader.name).write_text(code)
    for relative, namespace, call, kind in (
        ('src/core/arm/dynarmic/arm_dynarmic.cpp', 'namespace Core {', '    jit->Run();', 0),
        ('src/video_core/shader/shader_jit.cpp', 'namespace Pica::Shader {', '    shader->Run(setup, state, setup.entry_point);', 1)):
        original = source / relative
        code = replace(original.read_text(), namespace, 'extern "C" void ir_azahar_jit_executed(unsigned);\n\n' + namespace)
        code = replace(code, call, call + '\n    ir_azahar_jit_executed(' + str(kind) + ');')
        (directory / original.name).write_text(code)
    original = source / 'src/citra_libretro/citra_libretro.cpp'
    code = replace(original.read_text(), '#include "citra_libretro/libretro_vk.h"', '')
    code = replace(code, '    LibRetro::Input::Init();', '    LibRetro::Input::Init();\n    ir_azahar_register_camera();')
    code = 'extern "C" void ir_azahar_register_camera();\n' + code
    code = replace(code, '        LibRetro::VulkanResetContext();', '        // The native renderer owns its Metal surface and Vulkan device.')
    start = code.index('    case Settings::GraphicsAPI::Vulkan: {', code.index('bool retro_load_game'))
    end = code.index('    case Settings::GraphicsAPI::Software: {', start)
    code = code[:start] + '    case Settings::GraphicsAPI::Vulkan:\n' + code[end:]
    code += r'''
#include "IRCheats.h"
#include "core/cheats/cheats.h"
#include "core/cheats/gateway_cheat.h"
#include <sstream>
#include "common/file_util.h"
#include "core/hle/service/am/am.h"
#include <fstream>
#include "json.hpp"
extern "C" int ir_phase3_core_install_cia(const char* root, const char* file) {
    if (!root || !file || Core::System::GetInstance().IsPoweredOn()) return 100;
    const std::string previous = FileUtil::GetUserPath(FileUtil::UserPath::UserDir);
    struct Restore { std::string path; ~Restore() { FileUtil::SetUserPath(path); } } restore{previous};
    try {
        FileUtil::SetUserPath(std::string(root) + "/");
        bool compressed = false;
        auto status = Service::AM::CheckCIAToInstall(file, compressed, true);
        if (status == Service::AM::InstallStatus::Success) status = Service::AM::InstallCIA(file);
        if (status == Service::AM::InstallStatus::Success) {
            auto info = Service::AM::GetCIAInfos(file);
            if (info.Failed()) return 102;
            if (info.Succeeded()) {
                const u64 id = info.Unwrap().first.tid;
                if ((id >> 32) == 0x00040000) {
                    const auto path = Service::AM::GetTitleContentPath(Service::AM::GetTitleMediaType(id), id);
                    auto loader = Loader::GetLoader(path);
                    bool executable = false;
                    if (!loader || loader->IsExecutable(executable) != Loader::ResultStatus::Success || !executable) return 102;
                    std::string title;
                    loader->ReadTitle(title);
                    if (title.empty()) title = fmt::format("3DS Title {:016X}", id);
                    const std::string prefix = std::string(root) + "/";
                    if (path.rfind(prefix, 0) != 0) return 102;
                    std::ofstream manifest(std::string(root) + "/iridium-installed.json");
                    manifest << nlohmann::json{{"title", title}, {"path", path.substr(prefix.size())}};
                    if (!manifest.good()) return 102;
                }
            }
        }
        return static_cast<int>(status);
    } catch (...) { return 101; }
}
extern "C" bool ir_phase3_core_cheats(const IRCheat* items, size_t count) {
    if (!ir_cheats_valid(items, count)) return false;
    static std::vector<std::weak_ptr<Cheats::CheatBase>> managed;
    std::vector<std::shared_ptr<Cheats::CheatBase>> pending;
    for (size_t i = 0; i < count; ++i) {
        if (strcmp(items[i].format, "gateway")) return false;
        std::vector<Cheats::GatewayCheat::CheatLine> lines;
        std::istringstream stream(items[i].code);
        for (std::string line; std::getline(stream, line);) {
            if (line.find_first_not_of(" \t\r") == std::string::npos) continue;
            uint32_t first, second;
            if (!ir_cheat_pair(line.c_str(), &first, &second)) return false;
            char normalized[18]; snprintf(normalized, sizeof(normalized), "%08X %08X", first, second);
            lines.emplace_back(normalized);
            if (!lines.back().valid) return false;
        }
        if (lines.empty()) return false;
        auto cheat = std::make_shared<Cheats::GatewayCheat>(items[i].name, std::move(lines), "");
        cheat->SetEnabled(items[i].enabled); pending.push_back(std::move(cheat));
    }
    auto& engine = Core::System::GetInstance().CheatEngine();
    auto existing = engine.GetCheats();
    std::vector<size_t> removed;
    for (size_t i = 0; i < existing.size(); ++i)
        for (const auto& previous : managed) if (previous.lock() == existing[i]) { removed.push_back(i); break; }
    for (auto i = removed.rbegin(); i != removed.rend(); ++i) engine.RemoveCheat(*i);
    managed.clear();
    for (auto& cheat : pending) { managed.push_back(cheat); engine.AddCheat(std::move(cheat)); }
    return true;
}
'''
    (directory / original.name).write_text(code)
    original = source / 'src/citra_libretro/emu_window/libretro_window.cpp'
    code = replace(original.read_text(), 'EmuWindow_LibRetro::EmuWindow_LibRetro() {', 'extern "C" void* ir_azahar_metal_layer();\n\nEmuWindow_LibRetro::EmuWindow_LibRetro() {')
    code = replace(code, '    window_info.type = Frontend::WindowSystemType::LibRetro;', '    window_info.type = Frontend::WindowSystemType::MacOS;\n    window_info.render_surface = ir_azahar_metal_layer();')
    code = replace(code, '    if (Settings::values.graphics_api.GetValue() == Settings::GraphicsAPI::Software) {', '    if (Settings::values.graphics_api.GetValue() == Settings::GraphicsAPI::Software ||\n        Settings::values.graphics_api.GetValue() == Settings::GraphicsAPI::Vulkan) {')
    (directory / original.name).write_text(code)
    original = source / 'src/citra_libretro/input/mouse_tracker.cpp'
    code = replace(original.read_text(), '#include "video_core/renderer_vulkan/renderer_vulkan.h"', '')
    # Zero is the canvas center, not a missing pointer. Reject non-touchscreen
    # taps instead of pressing the previous valid point after a layout change.
    code = replace(code, '(pointerX != 0 || pointerY != 0) && (newX != lastMouseX || newY != lastMouseY)',
                   '(newX != lastMouseX || newY != lastMouseY)', 2)
    touch = '        state |= LibRetro::CheckInput(0, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_PRESSED);'
    code = replace(code, touch, '        bool touching = LibRetro::CheckInput(0, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_PRESSED);')
    marker = '        // Use mouse pointer movement'
    first = code.index(marker, code.index('bool touching ='))
    code = code[:first] + '        state |= touching && IsWithinTouchscreen(layout, newX, newY);\n\n' + code[first:]
    (directory / original.name).write_text(code)
    original = source / 'src/video_core/renderer_vulkan/vk_platform.cpp'
    code = replace(original.read_text(), 'namespace Vulkan {', 'extern "C" VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance, const char*);\n\nnamespace Vulkan {')
    start = code.index('    [[maybe_unused]] Frontend::GraphicsContext* context) {')
    end = code.index('\nvk::SurfaceKHR CreateSurface', start)
    code = code[:start] + '    [[maybe_unused]] Frontend::GraphicsContext* context) {\n    return std::make_shared<Common::DynamicLibrary>(nullptr);\n}\n' + code[end:]
    start = code.index('    if (!library.IsLoaded()) {')
    end = code.index('    VULKAN_HPP_DEFAULT_DISPATCHER.init(vkGetInstanceProcAddr);', start)
    code = code[:start] + '    const auto vkGetInstanceProcAddr = ::vkGetInstanceProcAddr;\n' + code[end:]
    (directory / original.name).write_text(code)


def check_compile_commands(build_dir, embedding):
    commands = json.loads((build_dir / 'compile_commands.json').read_text())
    for name in ('address_space.cpp', 'spin_lock_arm64.cpp', 'arm_dynarmic.cpp', 'shader_jit.cpp', 'shader_jit_a64_compiler.cpp', 'vk_platform.cpp', 'libretro_window.cpp', 'mouse_tracker.cpp', 'citra_libretro.cpp'):
        compiled = [Path(item['file']).resolve() for item in commands if Path(item['file']).name == name]
        if compiled != [(embedding / name).resolve()]:
            raise ValueError('Azahar must compile only its checked overlay: ' + name)
    source = Path(__file__).resolve().parents[1] / '.build/phase3-downloads' / source_archive().removesuffix('.tar.xz')
    compiled = [Path(item['file']).resolve() for item in commands if Path(item['file']).name == 'am.cpp']
    if compiled != [(source / 'src/core/hle/service/am/am.cpp').resolve()]:
        raise ValueError('Azahar must compile its pinned upstream CIA installer')
    if any(Path(item['file']).name in ('exception_handler_macos.cpp', 'exception_handler_macos_mig.c') for item in commands):
        raise ValueError('Azahar must not replace the shared debugger exception handlers')
    if any(Path(item['file']).name == 'libretro_vk.cpp' for item in commands):
        raise ValueError('Azahar must use its main Vulkan renderer')
    for item in commands:
        if '/src/video_core/' in item['file'] and '-DHAVE_LIBRETRO' in item['command']:
            raise ValueError('Azahar video must own its Vulkan device and presentation queue')


def prepare_source(ROOT, revision, downloads_spec):
    downloads = ROOT / '.build/phase3-downloads'
    for filename, expected in downloads_spec.items():
        if digest(downloads / filename) != expected:
            raise ValueError('Official release artifact digest differs: ' + filename)
    expanded = downloads / source_archive().removesuffix('.tar.xz')
    if not expanded.exists():
        with tarfile.open(downloads / source_archive()) as archive:
            archive.extractall(downloads, filter='data')
    if (expanded / 'GIT-COMMIT').read_text().strip() != revision:
        raise ValueError('Azahar unified source pin differs')
    archive_files = []
    with tarfile.open(downloads / source_archive()) as archive:
        for member in archive:
            relative = Path(member.name).relative_to(expanded.name)
            target = expanded / relative
            if member.isfile():
                if target.is_symlink() or digest(target) != hashlib.file_digest(archive.extractfile(member), 'sha256').hexdigest():
                    raise ValueError('Azahar expanded source changed: ' + relative.as_posix())
                archive_files.append(relative)
            elif member.issym() and (not target.is_symlink() or Path(target.readlink()) != Path(member.linkname)):
                raise ValueError('Azahar expanded source link changed')
    return expanded, archive_files


def arguments(moltenvk_library):
    return ['-DENABLE_LIBRETRO=ON', '-DENABLE_VULKAN=ON', '-DENABLE_OPT=OFF',
            '-DENABLE_LTO=OFF', '-DCITRA_USE_PRECOMPILED_HEADERS=OFF', '-DCITRA_WARNINGS_AS_ERRORS=OFF',
            '-DCMAKE_C_FLAGS=-DIOS', '-DCMAKE_CXX_FLAGS=-DIOS', '-DIRIDIUM_AZAHAR_MOLTENVK=' + str(moltenvk_library)]


def collect_licenses(ROOT, destination, moltenvk_receipt):
    for item in moltenvk_receipt['sourceInputs']:
        source_root = ROOT / '.build/azahar/moltenvk-source' / item['name']
        with tarfile.open(ROOT / '.build/runtime-downloads' / (item['sha256'] + '.tar')) as archive:
            for member in archive:
                relative = Path(*Path(member.name).parts[1:])
                if not member.isfile(): continue
                if not relative.name.lower().startswith(('license', 'copying', 'notice', 'copyright', 'authors')) and not any(part.lower() == 'licenses' for part in relative.parts): continue
                target = destination / 'licenses/MoltenVK' / item['name'] / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_root / relative, target)


TARGET, OUTPUT = 'citra_libretro', 'bin/Release/azahar_libretro.dylib'
