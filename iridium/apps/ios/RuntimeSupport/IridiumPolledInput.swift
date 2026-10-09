// SPDX-License-Identifier: AGPL-3.0-only

/// Digital input for sampled runtimes. The caller serializes all access.
///
/// A down/up pair must survive until two distinct, acknowledged core polls.
/// Sources advance independently, so releasing touch cannot release a key or
/// controller that is still held. Reads never consume an edge: a boot pump or
/// failed step that did not poll must retry the same snapshot.
/// D-pad bits share one ordered mask per source: combining independent queues
/// could invent a left+right or up+down chord during a direction change.
struct IridiumPolledInput {
    struct Snapshot {
        let buttons: UInt16
        fileprivate let generation: UInt64
        fileprivate let edges: [SampledEdge]
    }

    fileprivate struct SampledEdge {
        let source: String
        let control: Int
        let id: UInt64
    }

    private struct Edge {
        let id: UInt64
        let buttons: UInt16
    }

    private static let controlMasks: [UInt16] = [
        0x0001, 0x0002, 0x0004, 0x0008, 0x00f0,
        0x0100, 0x0200, 0x0400, 0x0800, 0x1000, 0x2000, 0x4000, 0x8000,
    ]

    private struct Source {
        var physical: UInt16 = 0
        var delivered: UInt16 = 0
        var pending = Array(repeating: [Edge](), count: IridiumPolledInput.controlMasks.count)

        var isReleased: Bool {
            physical == 0 && delivered == 0 && pending.allSatisfy(\.isEmpty)
        }
    }

    // Retain at most four transitions per source/control during a stalled core.
    // A control is one button or the complete D-pad mask. On
    // overflow preserve the first unacknowledged edge (possibly in flight),
    // then coalesce two interior transitions. This keeps ordering and the newest
    // physical state without endless replay or invented directional chords.
    static let maximumPendingEdges = 4
    private var sources: [String: Source] = [:]
    private var generation: UInt64 = 0
    private var nextEdgeID: UInt64 = 0

    mutating func setButton(_ mask: UInt16, pressed: Bool, source: String) {
        let current = sources[source]?.physical ?? 0
        setButtons(pressed ? current | mask : current & ~mask, source: source)
    }

    mutating func setButtons(_ buttons: UInt16, source: String) {
        var state = sources[source] ?? Source()
        let changed = state.physical ^ buttons
        guard changed != 0 else { return }
        state.physical = buttons
        for (control, mask) in Self.controlMasks.enumerated() where changed & mask != 0 {
            nextEdgeID &+= 1
            if state.pending[control].count == Self.maximumPendingEdges {
                state.pending[control].removeSubrange(1...2)
            }
            state.pending[control].append(Edge(id: nextEdgeID, buttons: buttons & mask))
        }
        sources[source] = state
    }

    func snapshot() -> Snapshot {
        var buttons: UInt16 = 0
        var edges: [SampledEdge] = []
        for (source, state) in sources {
            var sampled = state.delivered
            for (control, mask) in Self.controlMasks.enumerated() {
                guard let edge = state.pending[control].first else { continue }
                sampled = (sampled & ~mask) | edge.buttons
                edges.append(SampledEdge(source: source, control: control, id: edge.id))
            }
            buttons |= sampled
        }
        return Snapshot(buttons: buttons, generation: generation, edges: edges)
    }

    mutating func acknowledge(_ snapshot: Snapshot) {
        // A late completion after pause/rotation/session replacement cannot
        // consume a new session's input or reintroduce canceled state.
        guard snapshot.generation == generation else { return }
        for sampled in snapshot.edges {
            guard var state = sources[sampled.source],
                  let edge = state.pending[sampled.control].first,
                  edge.id == sampled.id else { continue }
            let mask = Self.controlMasks[sampled.control]
            state.delivered = (state.delivered & ~mask) | edge.buttons
            state.pending[sampled.control].removeFirst()
            if state.isReleased { sources.removeValue(forKey: sampled.source) }
            else { sources[sampled.source] = state }
        }
    }

    mutating func cancel() {
        generation &+= 1
        sources.removeAll(keepingCapacity: true)
    }

    // Internal diagnostics for deterministic bounds checks; no event history.
    var pendingEdgeCount: Int {
        sources.values.reduce(0) { $0 + $1.pending.reduce(0) { $0 + $1.count } }
    }
}
