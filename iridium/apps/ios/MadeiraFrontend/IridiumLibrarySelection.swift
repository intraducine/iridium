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

    static func verticalFocus(_ current: String, down: Bool, wide: Bool) -> String {
        let actions = ["play", "options"]
        let rows = [["filters"], ["search", "add", "settings"],
                    wide ? ["games"] : actions, wide ? actions : ["games"]]
        let index = rows.firstIndex { $0.contains(current) } ?? 2
        let next = min(rows.count - 1, max(0, index + (down ? 1 : -1)))
        return next == index ? current : rows[next][0]
    }

    /// Variable-width cards share a fixed leading focus area. Comparing actual
    /// overlap keeps the featured wide card and narrow covers on the same model.
    /// This observes native geometry; the native target behavior settles only after release.
    static func visibleIndex(offset: Double, widths: [Double], spacing: Double,
                             focusWidth: Double, previous: Int?) -> Int? {
        guard offset.isFinite, spacing.isFinite, spacing >= 0,
              focusWidth.isFinite, focusWidth > 0, !widths.isEmpty,
              widths.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let start = max(0, offset)
        var origin = 0.0, bestOverlap = -1.0, bestDistance = Double.infinity
        var best: Int?
        for (index, width) in widths.enumerated() {
            let overlap = max(0, min(origin + width, start + focusWidth) - max(origin, start))
            let distance = abs(origin + width / 2 - start - focusWidth / 2)
            if overlap > bestOverlap + 0.000001 ||
                (abs(overlap - bestOverlap) < 0.000001 &&
                 (overlap <= 0.000001 ? distance < bestDistance :
                    (index == previous || (best != previous && distance < bestDistance)))) {
                best = index; bestOverlap = overlap; bestDistance = distance
            }
            origin += width + spacing
        }
        return best
    }

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

    /// Native scrolling calls this once for its proposed resting position.
    /// Observing geometry still never sends a competing scroll request.
    static func restingOffset(_ offset: Double, widths: [Double], spacing: Double,
                              focusWidth: Double) -> Double? {
        guard let index = visibleIndex(offset: offset, widths: widths, spacing: spacing,
                                       focusWidth: focusWidth, previous: nil) else { return nil }
        return widths.prefix(index).reduce(0) { $0 + $1 + spacing }
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

/// Presentation order spans both runtime libraries without rewriting either one.
enum IridiumLibraryOrder {
    static let settingsKey = "iridium.libraryOrder"
    static func ordered(_ ids: [UUID], saved: String) -> [UUID] {
        var remaining = Set(ids)
        let stored = saved.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        return (stored + ids).filter { remaining.remove($0) != nil }
    }
    static func moving(_ id: UUID, relativeTo target: UUID, after: Bool, in ids: [UUID]) -> [UUID] {
        guard id != target, ids.contains(id), ids.contains(target) else { return ids }
        var result = ids.filter { $0 != id }
        let index = result.firstIndex(of: target)!
        result.insert(id, at: index + (after ? 1 : 0))
        return result
    }
    static func encoded(_ ids: [UUID]) -> String { ids.map(\.uuidString).joined(separator: ",") }
}
