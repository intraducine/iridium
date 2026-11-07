// SPDX-License-Identifier: GPL-2.0-or-later
#include "IRCameraSource.h"
#include "common/settings.h"
#include "core/frontend/camera/factory.h"
#include "core/frontend/camera/interface.h"
#include "core/hle/service/cam/cam.h"
#include <algorithm>
#include <array>
#include <memory>
#include <mutex>
#include <string>

static IRCameraSource source{};
static std::mutex sourceLock;
static IRCameraSource cameraSource() { std::lock_guard lock(sourceLock); return source; }
extern "C" bool ir_phase3_core_camera(const IRCameraSource* value) {
    if (!value || value->version != 1 || !value->request || !value->read) return false;
    std::lock_guard lock(sourceLock);
    source = *value;
    return true;
}
namespace {
class Camera final : public ::Camera::CameraInterface {
    const unsigned index;
    struct Configuration {
        unsigned width = 320, height = 240;
        Service::CAM::Flip flip = Service::CAM::Flip::NoFlip;
        Service::CAM::Effect effect = Service::CAM::Effect::NoEffect;
        bool active = false, rgb = false;
    } config;
    std::mutex settingsLock, frameLock;
    std::vector<uint32_t> pixels = std::vector<uint32_t>(640 * 480);
    static int clamp(int n) { return std::clamp(n, 0, 255); }
public:
    Camera(unsigned value, Service::CAM::Flip flip) : index(value) { config.flip = flip; }
    ~Camera() override { StopCapture(); }
    void StartCapture() override {
        std::lock_guard frame(frameLock);
        { std::lock_guard lock(settingsLock); config.active = true; }
        auto source = cameraSource();
        if (source.request) source.request(source.context, index, true);
    }
    void StopCapture() override {
        std::lock_guard frame(frameLock);
        bool active;
        { std::lock_guard lock(settingsLock); active = config.active; config.active = false; }
        auto source = cameraSource();
        if (active && source.request) source.request(source.context, index, false);
    }
    void SetResolution(const Service::CAM::Resolution& value) override {
        std::lock_guard lock(settingsLock);
        config.width = std::clamp<unsigned>(value.width, 2, 640) & ~1u;
        config.height = std::clamp<unsigned>(value.height, 1, 480);
    }
    void SetFlip(Service::CAM::Flip value) override { std::lock_guard lock(settingsLock); config.flip = value; }
    void SetEffect(Service::CAM::Effect value) override { std::lock_guard lock(settingsLock); config.effect = value; }
    void SetFormat(Service::CAM::OutputFormat value) override { std::lock_guard lock(settingsLock); config.rgb = value == Service::CAM::OutputFormat::RGB565; }
    void SetFrameRate(Service::CAM::FrameRate) override {}
    bool IsPreviewAvailable() override { std::lock_guard lock(settingsLock); return config.active; }
    std::vector<u16> ReceiveFrame() override {
        std::lock_guard frame(frameLock);
        Configuration snapshot;
        { std::lock_guard lock(settingsLock); snapshot = config; }
        const auto [width, height, flip, effect, active, rgb] = snapshot;
        const auto source = cameraSource();
        std::vector<u16> output(width * height, rgb ? 0 : 0x8000);
        unsigned w = 0, h = 0;
        if (!active || !source.read || !source.read(source.context, pixels.data(), pixels.size(), &w, &h) || !w || !h || w > 640 || h > 480) return output;
        bool mirror = flip == Service::CAM::Flip::Horizontal || flip == Service::CAM::Flip::Reverse;
        bool invert = flip == Service::CAM::Flip::Vertical || flip == Service::CAM::Flip::Reverse;
        for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; x += 2) {
            int yuv[2][3]{};
            for (unsigned k = 0; k < 2; ++k) {
                unsigned sx = (mirror ? width - 1 - x - k : x + k) * w / width;
                unsigned sy = (invert ? height - 1 - y : y) * h / height;
                uint32_t pixel = pixels[sy * w + sx];
                int r = (pixel >> 16) & 255, g = (pixel >> 8) & 255, b = pixel & 255;
                if (effect == Service::CAM::Effect::Negative || effect == Service::CAM::Effect::Negafilm) { r = 255-r; g = 255-g; b = 255-b; }
                if (effect == Service::CAM::Effect::Mono) r = g = b = (77*r + 150*g + 29*b) >> 8;
                if (effect == Service::CAM::Effect::Sepia || effect == Service::CAM::Effect::Sepia01) {
                    int l = (77*r + 150*g + 29*b) >> 8; r = clamp(l+30); g = clamp(l+10); b = clamp(l-20);
                }
                if (rgb) output[y*width+x+k] = (u16)(((r>>3)<<11)|((g>>2)<<5)|(b>>3));
                else {
                    yuv[k][0] = clamp(((66*r+129*g+25*b+128)>>8)+16);
                    yuv[k][1] = clamp(((-38*r-74*g+112*b+128)>>8)+128);
                    yuv[k][2] = clamp(((112*r-94*g-18*b+128)>>8)+128);
                }
            }
            if (!rgb) {
                output[y*width+x] = (u16)(yuv[0][0] | (((yuv[0][1]+yuv[1][1])/2)<<8));
                output[y*width+x+1] = (u16)(yuv[1][0] | (((yuv[0][2]+yuv[1][2])/2)<<8));
            }
        }
        return output;
    }
};
class Factory final : public ::Camera::CameraFactory {
public:
    std::unique_ptr<::Camera::CameraInterface> Create(const std::string& config, const Service::CAM::Flip& flip) override {
        unsigned index = config == "1" ? 1 : config == "2" ? 2 : 0;
        return std::make_unique<Camera>(index, flip);
    }
};
}
extern "C" void ir_azahar_register_camera() {
    ::Camera::RegisterFactory("iridium", std::make_unique<Factory>());
    for (size_t i = 0; i < Settings::values.camera_name.size(); ++i) {
        Settings::values.camera_name[i] = "iridium";
        Settings::values.camera_config[i] = std::to_string(i);
    }
}
