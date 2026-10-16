// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

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

    static func boundaries(from old: UUID?, to next: UUID?, in ids: [UUID]) -> Int {
        guard let old, let next, let a = ids.firstIndex(of: old), let b = ids.firstIndex(of: next) else { return 0 }
        return abs(a - b)
    }

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

/// One local reorder owns its payload until a completed or cancelled drag ends.
@Observable final class IridiumLibraryDragSession {
    struct Payload: Equatable {
        let gameID: UUID
        let token: UUID
    }
    @ObservationIgnored private(set) var active: Payload?
    struct Insertion: Equatable { let beforeID: UUID? }
    private(set) var insertion: Insertion?
    func begin(_ id: UUID) -> Payload {
        let payload = Payload(gameID: id, token: UUID())
        active = payload
        if insertion != nil { insertion = nil }
        return payload
    }
    /// Both edges of a gap name the same slot, excluding the lifted card.
    @discardableResult func preview(target: UUID, after: Bool, in ids: [UUID]) -> Bool {
        guard let active, ids.contains(active.gameID), ids.contains(target) else { return false }
        let remaining = ids.filter { $0 != active.gameID }
        let next: Insertion
        if target == active.gameID {
            let following = ids.drop(while: { $0 != target }).dropFirst().first
            next = Insertion(beforeID: following)
        } else {
            guard let index = remaining.firstIndex(of: target) else { return false }
            next = Insertion(beforeID: after ? remaining.dropFirst(index + 1).first : target)
        }
        guard insertion != next else { return false }
        insertion = next
        return true
    }
    func accepts(context: Payload?, item: Payload?, local: Bool, privateType: Bool) -> Bool {
        local && privateType && active != nil && context == active && item == active
    }
    func end(_ payload: Payload?) {
        if let payload, payload == active {
            active = nil
            if insertion != nil { insertion = nil }
        }
    }
}

#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

/// UIKit supplies the local-session identity and cancellation callback absent
/// from SwiftUI's item-provider closures. The card content and menu stay SwiftUI.
struct IridiumLibraryReorderCard<Content: View>: UIViewControllerRepresentable {
    static var typeIdentifier: String { "org.iridium.library-reorder" }
    let id: UUID
    let session: IridiumLibraryDragSession
    let order: [UUID]
    let commit: (UUID, UUID, Bool) -> Void
    var feedbackEnabled = true
    var trace: (String) -> Void = { _ in }
    @ViewBuilder var content: () -> Content
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        let host = UIHostingController(rootView: content())
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        container.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        host.didMove(toParent: container)
        let drag = UIDragInteraction(delegate: context.coordinator)
        drag.isEnabled = true
        container.view.addInteraction(drag)
        container.view.addInteraction(UIDropInteraction(delegate: context.coordinator))
        return container
    }
    func updateUIViewController(_ container: UIViewController, context: Context) {
        context.coordinator.parent = self
        (container.children.first as? UIHostingController<Content>)?.rootView = content()
    }
    static func dismantleUIViewController(_ container: UIViewController, coordinator: Coordinator) {
        coordinator.parent.session.end(coordinator.payload)
    }
    final class Coordinator: NSObject, UIDragInteractionDelegate, UIDropInteractionDelegate {
        var parent: IridiumLibraryReorderCard
        var payload: IridiumLibraryDragSession.Payload?
        private let feedback = UISelectionFeedbackGenerator()
        init(_ parent: IridiumLibraryReorderCard) { self.parent = parent }
        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
            // UIKit can request providers repeatedly for the same session.
            let current = session.localContext as? IridiumLibraryDragSession.Payload
            let value = current == parent.session.active && current?.gameID == parent.id
                ? current! : parent.session.begin(parent.id)
            payload = value
            session.localContext = value
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: IridiumLibraryReorderCard.typeIdentifier, visibility: .ownProcess) { completion in
                completion(Data(value.token.uuidString.utf8), nil); return nil
            }
            let item = UIDragItem(itemProvider: provider)
            item.localObject = value
            parent.trace("begin")
            feedback.prepare()
            return [item]
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool { true }
        func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
            parent.session.end(session.localContext as? IridiumLibraryDragSession.Payload)
            payload = nil
            parent.trace("ended")
        }
        func acceptedPayload(_ session: any UIDropSession) -> IridiumLibraryDragSession.Payload? {
            guard session.items.count == 1, let item = session.items.first,
                  let local = session.localDragSession,
                  let context = local.localContext as? IridiumLibraryDragSession.Payload,
                  parent.session.accepts(context: context, item: item.localObject as? IridiumLibraryDragSession.Payload,
                    local: true, privateType: item.itemProvider.hasItemConformingToTypeIdentifier(IridiumLibraryReorderCard.typeIdentifier)) else { return nil }
            return context
        }
        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
            acceptedPayload(session) != nil
        }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
            guard session.allowsMoveOperation, acceptedPayload(session) != nil, let view = interaction.view else {
                return UIDropProposal(operation: .cancel)
            }
            if parent.session.preview(target: parent.id, after: session.location(in: view).x > view.bounds.midX, in: parent.order) {
                if parent.feedbackEnabled { feedback.selectionChanged() }
                feedback.prepare()
                parent.trace("slot")
            }
            return UIDropProposal(operation: .move)
        }
        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
            guard session.allowsMoveOperation, let value = acceptedPayload(session), let view = interaction.view else { return }
            let after = session.location(in: view).x > view.bounds.width / 2
            parent.session.end(value)
            parent.commit(value.gameID, parent.id, after)
            parent.trace("committed")
        }
    }
}
#endif
