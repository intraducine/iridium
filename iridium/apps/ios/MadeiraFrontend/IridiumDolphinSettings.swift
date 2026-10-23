// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreMotion
import UIKit

struct IridiumDolphinSettings: Codable, Equatable {
    var resolution = 1
    var aspect = 0
    var remote = 0
    var players = 1
    var dualCore = true
    var motion = true
    var muted: Bool?
    var native: IRDolphinOptions {
        IRDolphinOptions(resolution: Int32(resolution), aspect: Int32(aspect), remote: Int32(remote),
                         players: Int32(players), dual_core: dualCore, use_jit: false, muted: false)
    }
    static func load(_ game: UUID) -> Self {
        guard let data = UserDefaults.standard.data(forKey: "Dolphin.\(game)"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        guard (1...4).contains(value.resolution), (0...2).contains(value.aspect),
              (0...2).contains(value.remote), (1...4).contains(value.players) else { return Self() }
        return value
    }
    func save(_ game: UUID) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "Dolphin.\(game)") }
    }
}

/// Sensor samples are copied under a lock. The emulation thread never reads UIKit.
final class IridiumDolphinMotion: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let lock = NSLock()
    private var orientation = UIInterfaceOrientation.portrait
    private var acceleration: (Float, Float, Float) = (0, 0, 9.81)
    private var rotation: (Float, Float, Float) = (0, 0, 0)
    func start(enabled: Bool) {
        stop()
        guard enabled, manager.isDeviceMotionAvailable else { return }
        updateOrientation()
        manager.deviceMotionUpdateInterval = 1 / 100
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        manager.startDeviceMotionUpdates(to: queue) { [weak self] sample, _ in
            guard let self, let sample else { return }
            let a = sample.gravity, u = sample.userAcceleration, r = sample.rotationRate
            self.lock.lock()
            let ax = a.x + u.x, ay = a.y + u.y
            let x: Double, y: Double, pitch: Double, roll: Double
            switch self.orientation {
            case .landscapeRight: (x, y, pitch, roll) = (ay, -ax, r.y, -r.x)
            case .landscapeLeft: (x, y, pitch, roll) = (-ay, ax, -r.y, r.x)
            case .portraitUpsideDown: (x, y, pitch, roll) = (ax, ay, r.x, r.y)
            default: (x, y, pitch, roll) = (-ax, -ay, -r.x, -r.y)
            }
            self.acceleration = (Float(x * -9.81), Float(y * -9.81), Float((a.z + u.z) * -9.81))
            self.rotation = (Float(pitch), Float(roll), Float(r.z))
            self.lock.unlock()
        }
    }
    func updateOrientation() {
        let value = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first ?? .portrait
        lock.lock(); orientation = value; lock.unlock()
    }
    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock(); acceleration = (0, 0, 9.81); rotation = (0, 0, 0); lock.unlock()
    }
    func fill(_ input: inout IRDolphinInput) {
        lock.lock(); defer { lock.unlock() }
        input.acceleration = acceleration; input.rotation = rotation
    }
}
