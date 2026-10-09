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
