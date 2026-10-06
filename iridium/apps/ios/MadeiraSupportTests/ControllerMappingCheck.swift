import Foundation

@main struct ControllerMappingCheck {
    static func main() throws {
        var configuration = PhysicalControllerConfiguration()
        var state = MadeiraControllerMappingState()
        let pressed = MadeiraControllerMappingState.Sample(buttons: 0x1000, rightTrigger: 1, leftY: 1)
        func update(_ samples: [Int: MadeiraControllerMappingState.Sample], time: Double = 1, active: Bool = true) -> [MadeiraControllerMappingState.Event] {
            state.update(samples: samples, configuration: configuration, active: active, timestamp: time)
        }
        precondition(update([0: pressed]).isEmpty, "native is the default")
        configuration.mode = .keyboardMouse
        let downs = Set(update([0: pressed]).compactMap { event -> PhysicalControllerAction? in
            if case .action(let action, true) = event { return action }; return nil
        })
        precondition(downs == [.key(0x20), .key(0x57), .mouseLeft])
        precondition(update([0: pressed], time: 1.01).isEmpty, "no repeated key downs")
        precondition(update([0: pressed, 1: pressed], time: 1.02).isEmpty)
        precondition(update([1: pressed], time: 1.03).isEmpty, "disconnect preserves another controller's holds")
        precondition(update([:]).count == 3 && state.held.isEmpty, "last disconnect releases every output")

        configuration.bindings["a"] = .key(0x57)
        precondition(update([0: pressed]).count == 2, "stick and button share W")
        var onlyStick = pressed; onlyStick.buttons = 0
        precondition(update([0: onlyStick]).isEmpty)
        precondition(update([0: onlyStick], active: false).count == 2 && state.held.isEmpty)
        precondition(update([0: pressed]).count == 2)
        configuration.bindings["a"] = .key(0x45)
        let changed = update([0: pressed])
        precondition(changed.contains(.action(.key(0x57), false)))
        precondition(changed.contains(.action(.key(0x45), true)), "remap releases previous actions")
        configuration.mode = .native
        precondition(update([0: pressed]).count == 3 && state.held.isEmpty)
        precondition(state.releaseAll().isEmpty)

        // Every modifier precedes letter/mouse downs and follows their ups.
        // Test normal transitions, disconnect/reset, remap and shared owners.
        for modifier: Int32 in [0x10, 0x11, 0x12] {
            var chord = PhysicalControllerConfiguration(); chord.mode = .keyboardMouse
            chord.bindings = ["a": .key(0x41), "b": .key(modifier), "x": .mouseLeft]
            let sample = MadeiraControllerMappingState.Sample(buttons: 0x7000)
            let downs: [MadeiraControllerMappingState.Event] = [.action(.key(modifier), true), .action(.key(0x41), true), .action(.mouseLeft, true)]
            let ups: [MadeiraControllerMappingState.Event] = [.action(.key(0x41), false), .action(.mouseLeft, false), .action(.key(modifier), false)]
            var chordState = MadeiraControllerMappingState()
            precondition(chordState.update(samples: [0: sample], configuration: chord, active: true, timestamp: 0) == downs)
            precondition(chordState.update(samples: [0: sample, 1: sample], configuration: chord, active: true, timestamp: 0.01).isEmpty)
            precondition(chordState.update(samples: [1: sample], configuration: chord, active: true, timestamp: 0.02).isEmpty)
            precondition(chordState.update(samples: [1: .init()], configuration: chord, active: true, timestamp: 0.03) == ups)
            precondition(chordState.update(samples: [0: sample], configuration: chord, active: true, timestamp: 0.04) == downs)
            precondition(chordState.releaseAll() == ups)
            precondition(chordState.update(samples: [0: sample], configuration: chord, active: true, timestamp: 0.05) == downs)
            precondition(chordState.update(samples: [:], configuration: chord, active: true, timestamp: 0.06) == ups)
            precondition(chordState.update(samples: [0: sample], configuration: chord, active: true, timestamp: 0.07) == downs)
            chord.bindings["a"] = .key(0x5a)
            let remap = chordState.update(samples: [0: sample], configuration: chord, active: true, timestamp: 0.08)
            precondition(Array(remap.prefix(3)) == ups)
            precondition(Array(remap.suffix(3)) == [.action(.key(modifier), true), .action(.key(0x5a), true), .action(.mouseLeft, true)])
        }
        var combined = PhysicalControllerConfiguration(); combined.mode = .keyboardMouse
        combined.bindings = ["a": .key(0x41), "b": .key(0x10), "x": .key(0x11), "y": .key(0x12)]
        var combinedState = MadeiraControllerMappingState()
        precondition(combinedState.update(samples: [0: .init(buttons: 0xf000, rightTrigger: 1)], configuration: combined,
                                          active: true, timestamp: 0) == [.action(.key(0x10), true), .action(.key(0x11), true), .action(.key(0x12), true), .action(.key(0x41), true), .action(.mouseLeft, true)])
        precondition(combinedState.releaseAll() == [.action(.key(0x41), false), .action(.mouseLeft, false), .action(.key(0x10), false), .action(.key(0x11), false), .action(.key(0x12), false)])

        configuration = .init(); configuration.mode = .keyboardMouse
        state = .init()
        let diagonal = MadeiraControllerMappingState.Sample(leftX: 1, leftY: 1)
        precondition(update([0: diagonal]).count == 2)
        precondition(state.held == [.key(0x57), .key(0x44)])
        precondition(update([0: .init(leftX: 0.1, leftY: 0.1)]).count == 2)
        precondition(update([0: .init(leftTrigger: 0.49, rightTrigger: .nan, leftX: .infinity)]).isEmpty)
        precondition(update([0: .init(leftTrigger: 0.5)]) == [.action(.mouseRight, true)])
        precondition(update([0: .init(leftTrigger: 0.49)]) == [.action(.mouseRight, false)])
        configuration.rightStick = .arrows
        precondition(update([0: .init(rightX: -1, rightY: -1)]).count == 2)
        precondition(state.held == [.key(0x25), .key(0x28)])

        func movement(hz: Int, count: Int = 1) -> Int32 {
            var value = PhysicalControllerConfiguration(); value.mode = .keyboardMouse
            var state = MadeiraControllerMappingState()
            let pads = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, MadeiraControllerMappingState.Sample(rightX: 1)) })
            var total: Int32 = 0
            for tick in 0...hz {
                for event in state.update(samples: pads, configuration: value, active: true, timestamp: Double(tick) / Double(hz)) {
                    if case .motion(let x, _) = event { total += x }
                }
            }
            return total
        }
        precondition(abs(movement(hz: 60) - movement(hz: 250)) <= 1, "sample frequency cannot change speed")
        precondition(abs(movement(hz: 1000) - 900) <= 1, "no minimum time floor")
        precondition(movement(hz: 60, count: 4) == movement(hz: 60), "multiple pads do not multiply mouse speed")
        configuration = .init(); configuration.mode = .keyboardMouse
        state = .init()
        precondition(update([0: .init(rightY: 1)], time: 10).isEmpty)
        precondition(update([0: .init(rightY: 1)], time: 10).isEmpty, "same timestamp cannot move")
        precondition(update([0: .init(rightY: 1)], time: 9).isEmpty, "clock rollback cannot move")
        let capped = update([0: .init(rightY: 1)], time: 100)
        precondition(capped == [.motion(0, -60)], "a long pause cannot jump the cursor")
        precondition(update([0: .init(rightY: 1)], active: false).isEmpty)
        precondition(update([0: .init(rightY: 1)], time: 101).isEmpty, "resume resets clock and carry")

        let suite = "IridiumControllerCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let oldLibrary = Data("{\"legacyLibrary\":true}".utf8)
        defaults.set(oldLibrary, forKey: "IridiumLibrary")
        defaults.set(oldLibrary, forKey: "IridiumTouchControllerLayout.\(first.uuidString)")
        precondition(PhysicalControllerMappingStore.configuration(for: first, defaults: defaults).mode == .native)
        configuration.bindings["a"] = PhysicalControllerAction.none
        PhysicalControllerMappingStore.save(configuration, for: first, defaults: defaults)
        precondition(PhysicalControllerMappingStore.configuration(for: first, defaults: defaults) == configuration)
        precondition(PhysicalControllerMappingStore.configuration(for: second, defaults: defaults).mode == .native)
        precondition(defaults.data(forKey: "IridiumLibrary") == oldLibrary)
        precondition(defaults.data(forKey: "IridiumTouchControllerLayout.\(first.uuidString)") == oldLibrary)
        defaults.set(Data("invalid".utf8), forKey: PhysicalControllerMappingStore.key(for: second))
        precondition(PhysicalControllerMappingStore.configuration(for: second, defaults: defaults).mode == .native)
        precondition(defaults.data(forKey: PhysicalControllerMappingStore.key(for: second)) == Data("invalid".utf8))
        var future = configuration; future.version = 2
        let futureData = try JSONEncoder().encode(future)
        defaults.set(futureData, forKey: PhysicalControllerMappingStore.key(for: second))
        precondition(PhysicalControllerMappingStore.configuration(for: second, defaults: defaults).mode == .native)
        precondition(defaults.data(forKey: PhysicalControllerMappingStore.key(for: second)) == futureData)
        configuration.deadZone = .nan; configuration.mouseSpeed = .infinity
        configuration.bindings["a"] = .key(-1); configuration.bindings["unknown"] = .mouseLeft
        precondition(configuration.validated.deadZone == 0.35 && configuration.validated.mouseSpeed == 900)
        precondition(configuration.validated.bindings.isEmpty)
        print("PASS controller mapping defaults, releases, conflicts, repeats, timing, dead zones and per-game persistence")
        print("PASS Shift/Control/Alt chord ordering for letters/mouse, coalescing, disconnect, reset and remap")
    }
}
