// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Native scrolling owns geometry until momentum settles. Focus navigation
/// requests a scroll explicitly; observing a scroll never requests another one.
struct IridiumLibrarySelection {
    enum Phase: Equatable { case idle, tracking, interacting, decelerating, animating }
    private(set) var phase: Phase = .idle
    private(set) var selectedID: UUID?
    private(set) var visibleID: UUID?
    private(set) var deferredFocusID: UUID?
    private var touchOwnsScroll = false
    var userIsScrolling: Bool { touchOwnsScroll }
    /// Preview moves with native touch scrolling, without issuing a scroll request.
    var highlightedID: UUID? { userIsScrolling ? (visibleID ?? selectedID) : selectedID }

    /// The cover with greatest overlap in the leading selection slot wins.
    /// Keeping exact ties stable avoids flicker when a drag pauses at a midpoint.
    static func visibleIndex(offset: Double, stride: Double, count: Int, previous: Int?) -> Int? {
        guard count > 0, offset.isFinite, stride.isFinite, stride > 0 else { return nil }
        let position = min(Double(count - 1), max(0, offset / stride))
        let lower = Int(position.rounded(.down))
        let fraction = position - Double(lower)
        if abs(fraction - 0.5) < 0.000001, let previous, previous == lower || previous == lower + 1 {
            return previous
        }
        return min(count - 1, lower + (fraction > 0.5 ? 1 : 0))
    }

    mutating func reconcile(_ ids: [UUID]) -> UUID? {
        if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
        if !ids.contains(where: { $0 == visibleID }) { visibleID = selectedID }
        if !ids.contains(where: { $0 == deferredFocusID }) { deferredFocusID = nil }
        return userIsScrolling ? nil : selectedID
    }
    mutating func select(_ id: UUID) -> UUID? {
        if userIsScrolling { deferredFocusID = id; return nil }
        selectedID = id; visibleID = id
        return id
    }
    mutating func observed(_ id: UUID?) {
        guard userIsScrolling, let id else { return }
        visibleID = id
    }
    mutating func transition(to next: Phase) -> UUID? {
        let wasUserDriven = touchOwnsScroll
        phase = next
        if [.tracking, .interacting, .decelerating].contains(next) { touchOwnsScroll = true }
        // SwiftUI can animate its snap after a drag. Ownership lasts through
        // that animation, not just through the finger/deceleration phases.
        guard next == .idle else { return nil }
        touchOwnsScroll = false
        if let deferred = deferredFocusID {
            deferredFocusID = nil; selectedID = deferred; visibleID = deferred
            return deferred
        }
        if wasUserDriven { selectedID = visibleID }
        return nil
    }
}
