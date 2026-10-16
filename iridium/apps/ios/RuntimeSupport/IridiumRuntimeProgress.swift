// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Bridge observations are independent of game-specific loading milestones.
struct IridiumRuntimeProgress: Equatable, Sendable {
    var phase = "starting"
    var sampledUptime = ProcessInfo.processInfo.systemUptime
    var runtimeSteps: UInt64 = 0
    var videoCallbacks: UInt64 = 0
    var freshImages: UInt64 = 0
    var changedImages: UInt64 = 0
    var displayedImages: UInt64 = 0
    var inputPolls: UInt64 = 0
    var audioFrames: UInt64 = 0
    var elapsedSeconds: Double = 0
    var secondsSinceFreshImage: Double?
    var secondsSinceChangedImage: Double?

    var summary: String {
        "\(phase.capitalized) · \(Int(elapsedSeconds)) s\nRuntime steps: \(runtimeSteps) · Input polls: \(inputPolls)\nVideo callbacks: \(videoCallbacks) · Fresh images: \(freshImages)\nChanged images: \(changedImages) · Displayed images: \(displayedImages)\nAudio frames produced: \(audioFrames)"
    }
    var observation: String {
        let age = max(0, ProcessInfo.processInfo.systemUptime - sampledUptime)
        if phase == "paused" { return "The runtime is paused. Resume to continue execution." }
        if phase == "pause requested" { return age >= 10 ? "Pause requested; no completed runtime operation for \(Int(age)) seconds. The runtime may be busy or stalled." : "Waiting for the current runtime operation to reach a safe pause point." }
        if phase == "booting (pause requested)" { return age >= 10 ? "Startup has not reported a completed operation for \(Int(age)) seconds. It may be busy or stalled; gameplay remains paused." : "Startup is still being processed. Gameplay will remain paused when startup completes." }
        if ["closed", "failed", "restart required", "stop timed out"].contains(phase) {
            return "Runtime state: \(phase). Check the latest entries for details."
        }
        if age >= 10 {
            return "No completed runtime step reported for \(Int(age)) seconds. The runtime may be busy or stalled; game progress is unknown."
        }
        guard freshImages > 0 else {
            return runtimeSteps == 0 ? "Waiting for the runtime's first completed step. No image received yet." : "The runtime is responding to steps. No image has been received yet; game loading progress is unknown."
        }
        if let secondsSinceFreshImage, secondsSinceFreshImage >= 10 {
            return "No fresh image for \(Int(secondsSinceFreshImage)) seconds. The runtime may be waiting or stalled; game loading progress is unknown."
        }
        if let secondsSinceChangedImage, secondsSinceChangedImage >= 10 {
            return "Images are arriving, but the displayed content has stayed the same for \(Int(secondsSinceChangedImage)) seconds. This can be a static screen or a stall."
        }
        return "Images are arriving and changing. Game loading progress is not measured."
    }
    var logLine: String {
        "[Console] phase=\(phase) elapsed_s=\(Int(elapsedSeconds)) steps=\(runtimeSteps) video_callbacks=\(videoCallbacks) fresh_images=\(freshImages) changed_images=\(changedImages) displayed_images=\(displayedImages) input_polls=\(inputPolls) audio_frames=\(audioFrames) image_age_s=\(secondsSinceFreshImage.map { String(Int($0)) } ?? "none") change_age_s=\(secondsSinceChangedImage.map { String(Int($0)) } ?? "none") game_progress=unknown"
    }
}
