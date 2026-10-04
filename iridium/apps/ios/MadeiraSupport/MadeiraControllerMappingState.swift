import Foundation

// Pure state: a monotonic timestamp and snapshots in, transition events out.
// Repeated samples never repeat a down event. Shared bindings and controllers
// hold one output until its last owner releases it.
struct MadeiraControllerMappingState {
    struct Sample {
        var buttons: UInt16 = 0
        var leftTrigger: Float = 0
        var rightTrigger: Float = 0
        var leftX: Float = 0
        var leftY: Float = 0
        var rightX: Float = 0
        var rightY: Float = 0
    }
    enum Event: Equatable {
        case action(PhysicalControllerAction, Bool)
        case motion(Int32, Int32)
    }

    private(set) var held: Set<PhysicalControllerAction> = []
    private var previousConfiguration: PhysicalControllerConfiguration?
    private var previousTime: TimeInterval?
    private var remainderX = 0.0
    private var remainderY = 0.0

    mutating func releaseAll() -> [Event] {
        let events = ordered(held, pressed: false).map { Event.action($0, false) }
        held.removeAll()
        previousTime = nil
        remainderX = 0
        remainderY = 0
        return events
    }

    mutating func update(samples: [Int: Sample], configuration: PhysicalControllerConfiguration,
                         active: Bool, timestamp: TimeInterval) -> [Event] {
        let configuration = configuration.validated
        var events: [Event] = []
        if previousConfiguration != configuration {
            events += releaseAll()
            previousConfiguration = configuration
        }
        guard active, configuration.mode == .keyboardMouse, !samples.isEmpty, timestamp.isFinite else {
            return events + releaseAll()
        }
        let dt = previousTime.map { min(1.0 / 15, max(0, timestamp - $0)) } ?? 0
        previousTime = timestamp
        var wanted = Set<PhysicalControllerAction>()
        var mouse = (x: 0.0, y: 0.0)
        for index in samples.keys.sorted() {
            guard let sample = samples[index] else { continue }
            for button in PhysicalControllerButton.allCases {
                let pressed: Bool
                switch button {
                case .lt: pressed = sample.leftTrigger.isFinite && sample.leftTrigger >= 0.5
                case .rt: pressed = sample.rightTrigger.isFinite && sample.rightTrigger >= 0.5
                default: pressed = sample.buttons & button.mask != 0
                }
                if pressed { wanted.insert(configuration.action(for: button)) }
            }
            for (stick, x, y) in [(configuration.leftStick, sample.leftX, sample.leftY),
                                  (configuration.rightStick, sample.rightX, sample.rightY)] {
                let x = Self.axis(x), y = Self.axis(y)
                if let keys = stick.keys {
                    wanted.formUnion(Self.directionKeys(x: x, y: y, deadZone: configuration.deadZone, keys: keys).map { .key($0) })
                } else if stick == .mouse {
                    let vector = Self.mouseVector(x: x, y: y, deadZone: configuration.deadZone)
                    // Two sticks/controllers must not multiply cursor speed.
                    if vector.x * vector.x + vector.y * vector.y > mouse.x * mouse.x + mouse.y * mouse.y {
                        mouse = vector
                    }
                }
            }
        }
        wanted.remove(.none)
        events += ordered(held.subtracting(wanted), pressed: false).map { .action($0, false) }
        events += ordered(wanted.subtracting(held), pressed: true).map { .action($0, true) }
        held = wanted

        if mouse.x == 0 && mouse.y == 0 {
            remainderX = 0; remainderY = 0
        } else {
            let x = mouse.x * configuration.mouseSpeed * dt + remainderX
            let y = -mouse.y * configuration.mouseSpeed * dt + remainderY
            let dx = Int32(x.rounded(.towardZero)), dy = Int32(y.rounded(.towardZero))
            remainderX = x - Double(dx); remainderY = y - Double(dy)
            if dx != 0 || dy != 0 { events.append(.motion(dx, dy)) }
        }
        return events
    }

    private func ordered(_ actions: Set<PhysicalControllerAction>, pressed: Bool) -> [PhysicalControllerAction] {
        // Chords press modifiers first and release them last, including reset,
        // disconnect and remap. Numeric ordering is independent of UI labels.
        func order(_ action: PhysicalControllerAction) -> (Int, Int32) {
            let modifier: Bool
            if case .key(let key) = action {
                modifier = [0x10, 0x11, 0x12, 0x5b, 0x5c, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5].contains(key)
            } else { modifier = false }
            let group = modifier == pressed ? 0 : 1
            switch action {
            case .key(let key): return (group, key)
            case .mouseLeft: return (group, 0x100)
            case .mouseRight: return (group, 0x101)
            case .mouseMiddle: return (group, 0x102)
            case .none: return (group, 0x103)
            }
        }
        return actions.sorted { order($0) < order($1) }
    }
    private static func axis(_ value: Float) -> Double { value.isFinite ? Double(min(1, max(-1, value))) : 0 }

    // Madeira's eight sectors: up at 0 degrees, clockwise in 45-degree steps.
    private static func directionKeys(x: Double, y: Double, deadZone: Double, keys: [Int32]) -> [Int32] {
        guard hypot(x, y) >= deadZone else { return [] }
        var angle = atan2(x, y)
        if angle < 0 { angle += 2 * .pi }
        switch Int((angle + .pi / 8) / (.pi / 4)) % 8 {
        case 0: return [keys[0]]
        case 1: return [keys[0], keys[1]]
        case 2: return [keys[1]]
        case 3: return [keys[2], keys[1]]
        case 4: return [keys[2]]
        case 5: return [keys[2], keys[3]]
        case 6: return [keys[3]]
        default: return [keys[0], keys[3]]
        }
    }
    private static func mouseVector(x: Double, y: Double, deadZone: Double) -> (x: Double, y: Double) {
        let magnitude = hypot(x, y)
        guard magnitude > deadZone else { return (0, 0) }
        let strength = (min(1, magnitude) - deadZone) / (1 - deadZone)
        return (x / magnitude * strength, y / magnitude * strength)
    }
}
