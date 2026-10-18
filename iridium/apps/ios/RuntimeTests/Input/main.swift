// SPDX-License-Identifier: AGPL-3.0-only

func tap(_ input: inout IridiumPolledInput, _ button: UInt16 = 1, source: String = "touch") {
    input.setButton(button, pressed: true, source: source)
    input.setButton(button, pressed: false, source: source)
}

func poll(_ input: inout IridiumPolledInput) -> UInt16 {
    let sample = input.snapshot()
    input.acknowledge(sample)
    return sample.buttons
}

// A complete tap between polls survives boot pumps that never poll.
do {
    var input = IridiumPolledInput()
    tap(&input)
    for _ in 0..<1000 {
        precondition(input.snapshot().buttons == 1)
        precondition(input.pendingEdgeCount == 2)
    }
    precondition(poll(&input) == 1)
    precondition(poll(&input) == 0)
    precondition(input.pendingEdgeCount == 0 && poll(&input) == 0)
}

// Two quick taps need an observed release between the observed downs.
do {
    var input = IridiumPolledInput()
    tap(&input); tap(&input)
    precondition((0..<4).map { _ in poll(&input) } == [1, 0, 1, 0])
    precondition(input.pendingEdgeCount == 0)
}

// Holding does not synthesize repeats; repeated touch/key-down events coalesce.
do {
    var input = IridiumPolledInput()
    input.setButton(1, pressed: true, source: "keyboard")
    for _ in 0..<1000 { input.setButton(1, pressed: true, source: "keyboard") }
    precondition(input.pendingEdgeCount == 1 && poll(&input) == 1)
    for _ in 0..<100 { precondition(poll(&input) == 1) }
    precondition(input.pendingEdgeCount == 0)
    input.setButton(1, pressed: false, source: "keyboard")
    precondition(poll(&input) == 0 && input.pendingEdgeCount == 0)
}

// Release during a running step belongs to the next poll; snapshots are values.
do {
    var input = IridiumPolledInput()
    input.setButton(1, pressed: true, source: "touch")
    let inFlight = input.snapshot()
    input.setButton(1, pressed: false, source: "touch")
    precondition(inFlight.buttons == 1 && input.pendingEdgeCount == 2)
    input.acknowledge(inFlight)
    input.acknowledge(inFlight) // Duplicate completion cannot consume the release.
    precondition(input.pendingEdgeCount == 1 && poll(&input) == 0)
}

// Independent sources own their holds, including two touches on the same bit.
do {
    var input = IridiumPolledInput()
    tap(&input, source: "touch.a")
    input.setButton(1, pressed: true, source: "keyboard")
    precondition(poll(&input) == 1 && poll(&input) == 1)
    input.setButton(1, pressed: true, source: "touch.b")
    input.setButton(1, pressed: false, source: "keyboard")
    precondition(poll(&input) == 1)
    input.setButton(1, pressed: false, source: "touch.b")
    precondition(poll(&input) == 0 && input.pendingEdgeCount == 0)
}

// Chords and releases advance independently per button, not as a global FIFO.
do {
    var input = IridiumPolledInput()
    tap(&input, 1)
    input.setButton(2, pressed: true, source: "touch")
    precondition(poll(&input) == 3 && poll(&input) == 2)
    input.setButton(2, pressed: false, source: "touch")
    input.setButtons(0x8004, source: "controller")
    precondition(poll(&input) == 0x8004)
    input.setButtons(0, source: "controller")
    precondition(poll(&input) == 0)
}

// A stalled core cannot accumulate unbounded replay. Overflow cannot replace
// the first unacknowledged edge, even while its immutable sample is in flight.
do {
    var input = IridiumPolledInput()
    tap(&input)
    let inFlight = input.snapshot()
    for _ in 0..<10000 {
        tap(&input)
        precondition(input.pendingEdgeCount <= IridiumPolledInput.maximumPendingEdges)
        precondition(input.snapshot().buttons == 1)
    }
    input.acknowledge(inFlight)
    precondition(poll(&input) == 0)
    for _ in 0..<IridiumPolledInput.maximumPendingEdges { _ = poll(&input) }
    precondition(input.pendingEdgeCount == 0 && poll(&input) == 0)

    for _ in 0..<10000 { tap(&input) }
    input.setButton(1, pressed: true, source: "touch")
    for _ in 0..<IridiumPolledInput.maximumPendingEdges { _ = poll(&input) }
    precondition(input.pendingEdgeCount == 0 && poll(&input) == 1)
    input.setButton(1, pressed: false, source: "touch")
    precondition(poll(&input) == 0)
}

// Pause/focus loss/rotation/stop/session replacement share cancellation.
// A late old core completion must not acknowledge the new session's press.
do {
    var input = IridiumPolledInput()
    tap(&input)
    let old = input.snapshot()
    input.cancel()
    precondition(input.pendingEdgeCount == 0 && input.snapshot().buttons == 0)
    input.acknowledge(old)
    precondition(poll(&input) == 0)
    tap(&input)
    input.acknowledge(old)
    precondition(input.pendingEdgeCount == 2)
    precondition(poll(&input) == 1 && poll(&input) == 0)
    input.setButton(1, pressed: true, source: "controller")
    precondition(poll(&input) == 1)
    input.cancel()
    precondition(poll(&input) == 0)
}

let up: UInt16 = 1 << 4
let down: UInt16 = 1 << 5
let left: UInt16 = 1 << 6
let right: UInt16 = 1 << 7

// Direction changes are ordered masks, never independent per-bit heads that
// invent opposing directions a single source never held together.
for (first, second) in [(right, left), (up, down), (left, right), (down, up)] {
    var input = IridiumPolledInput()
    input.setButtons(first, source: "touch.dpad")
    input.setButtons(second, source: "touch.dpad")
    precondition(poll(&input) == first)
    precondition(poll(&input) == second)
    input.setButtons(0, source: "touch.dpad")
    precondition(poll(&input) == 0 && input.pendingEdgeCount == 0)
}

// Real diagonals and changes between them retain exactly the supplied states.
do {
    var input = IridiumPolledInput()
    let states = [up | right, up | left, down | left, down]
    for state in states { input.setButtons(state, source: "touch.dpad") }
    precondition(states.map { _ in poll(&input) } == states)
    input.setButtons(0, source: "touch.dpad")
    precondition(poll(&input) == 0)

    let roll = [right, right | up, up, up | left]
    for state in roll { input.setButtons(state, source: "touch.dpad") }
    precondition(roll.map { _ in poll(&input) } == roll)
}

// Directional taps retain their neutral gap just like face-button taps.
do {
    var input = IridiumPolledInput()
    tap(&input, right, source: "touch.dpad")
    tap(&input, right, source: "touch.dpad")
    precondition((0..<4).map { _ in poll(&input) } == [right, 0, right, 0])
}

// A held direction from another source survives changes/releases of this one.
// OR between independent sources remains intentional, including opposites.
do {
    var input = IridiumPolledInput()
    input.setButtons(up, source: "keyboard")
    precondition(poll(&input) == up)
    input.setButtons(right, source: "touch.dpad")
    input.setButtons(left, source: "touch.dpad")
    precondition(poll(&input) == (up | right))
    precondition(poll(&input) == (up | left))
    input.setButtons(0, source: "touch.dpad")
    precondition(poll(&input) == up)
    tap(&input, down, source: "touch.dpad")
    precondition(poll(&input) == (up | down))
    precondition(poll(&input) == up)
    input.setButtons(0, source: "keyboard")
    precondition(poll(&input) == 0)
}

// Independent face-button chords are not serialized behind the D-pad stream.
do {
    var input = IridiumPolledInput()
    input.setButtons(right, source: "touch")
    input.setButtons(left | 1 | 2, source: "touch")
    precondition(poll(&input) == (right | 1 | 2))
    precondition(poll(&input) == (left | 1 | 2))
    input.setButtons(0, source: "touch")
    precondition(poll(&input) == 0)
}

// Direction overflow preserves the in-flight head and only real directional
// states. The newest held state is reached in a bounded number of polls.
do {
    var input = IridiumPolledInput()
    input.setButtons(right, source: "touch.dpad")
    let inFlight = input.snapshot()
    let states = [left, up, down, right]
    for index in 0..<10000 {
        input.setButtons(states[index % states.count], source: "touch.dpad")
        precondition(input.pendingEdgeCount <= IridiumPolledInput.maximumPendingEdges)
        precondition(input.snapshot().buttons == right)
    }
    input.setButtons(left, source: "touch.dpad")
    input.acknowledge(inFlight)
    let remaining = input.pendingEdgeCount
    input.acknowledge(inFlight)
    precondition(input.pendingEdgeCount == remaining)
    for _ in 0..<IridiumPolledInput.maximumPendingEdges {
        precondition(states.contains(poll(&input)))
    }
    precondition(input.pendingEdgeCount == 0 && poll(&input) == left)
    input.setButtons(0, source: "touch.dpad")
    precondition(poll(&input) == 0)

    input.setButtons(right, source: "touch.dpad")
    let old = input.snapshot()
    input.cancel()
    tap(&input, left, source: "touch.dpad")
    input.acknowledge(old)
    precondition(poll(&input) == left && poll(&input) == 0)
}

print("PASS: sampled taps, ordered directions, double taps, holds, source ownership, chords, bounded stalls and generation-safe cancellation")
