// SPDX-License-Identifier: AGPL-3.0-only
import CoreHaptics
import Foundation
import GameController

@MainActor final class IridiumControllerRumble {
    private struct Output {
        let controller: GCController
        let engine: CHHapticEngine
        let player: any CHHapticAdvancedPatternPlayer
        let generation: UUID
        var motors: [Float] = [0, 0]
        var running = false
    }
    private var outputs: [ObjectIdentifier: Output] = [:]

    func set(_ controller: GCController, motor: Int, strength: UInt16) {
        guard (0...1).contains(motor), GCController.controllers().contains(where: { $0 === controller }) else { return }
        let key = ObjectIdentifier(controller)
        do {
            if outputs[key] == nil {
                guard strength > 0, let engine = controller.haptics?.createEngine(withLocality: .default) else { return }
                engine.playsHapticsOnly = true
                let generation = UUID()
                engine.resetHandler = { [weak self] in Task { @MainActor in self?.remove(key, matching: generation) } }
                engine.stoppedHandler = { [weak self] _ in Task { @MainActor in self?.remove(key, matching: generation) } }
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    .init(parameterID: .hapticIntensity, value: 1),
                    .init(parameterID: .hapticSharpness, value: 0.5),
                ], relativeTime: 0, duration: 1)
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                player.loopEnabled = true
                outputs[key] = Output(controller: controller, engine: engine, player: player, generation: generation)
            }
            guard var output = outputs[key] else { return }
            let value = Float(strength) / 65535
            if output.motors[motor] == value { return }
            output.motors[motor] = value
            let intensity = max(output.motors[0], output.motors[1])
            if intensity == 0 {
                if output.running { try output.player.stop(atTime: CHHapticTimeImmediate) }
                output.running = false
            } else {
                if !output.running { try output.engine.start() }
                try output.player.sendParameters([.init(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)], atTime: CHHapticTimeImmediate)
                if !output.running { try output.player.start(atTime: CHHapticTimeImmediate) }
                output.running = true
            }
            outputs[key] = output
        } catch { remove(key) }
    }
    private func remove(_ key: ObjectIdentifier, matching generation: UUID? = nil) {
        if let generation, outputs[key]?.generation != generation { return }
        guard let output = outputs.removeValue(forKey: key) else { return }
        output.engine.resetHandler = {}; output.engine.stoppedHandler = { _ in }
        try? output.player.stop(atTime: CHHapticTimeImmediate)
        output.engine.stop(completionHandler: nil)
    }
    func stopAll() { for key in Array(outputs.keys) { remove(key) } }
    func stop(_ controller: GCController) { remove(ObjectIdentifier(controller)) }
}
