// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumLaunchMemoryView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                if let memory = RuntimeMemorySnapshot.sample() {
                    Text("RAM: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: memory.usedBytes), countStyle: .memory))")
                    if let available = memory.availableBytes {
                        ProgressView(value: Double(memory.usedBytes), total: max(1, Double(memory.usedBytes) + Double(available)))
                            .tint(.white).accessibilityLabel("App memory use")
                        Text("Available to app: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: available), countStyle: .memory))")
                    }
                } else { Text("RAM reading unavailable") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption.monospacedDigit()).foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine).accessibilityIdentifier("launchMemoryStatus")
        }
    }
}

/// One loading layout for every runtime; engines supply status and actions.
struct IridiumGameLoadingView<Cover: View, Status: View, Actions: View>: View {
    let title: String
    var wideEnabled = true
    @ViewBuilder var cover: Cover
    @ViewBuilder var status: Status
    @ViewBuilder var actions: Actions
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let width = max(0, geometry.size.width - insets.leading - insets.trailing - 48)
            let height = max(0, geometry.size.height - insets.top - insets.bottom - 48)
            let wide = wideEnabled && width > height && !typeSize.isAccessibilitySize
            let coverHeight = wide ? min(360, max(90, height * 0.8)) : min(180, height * 0.3)
            ScrollView {
                let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 28))
                    : AnyLayout(VStackLayout(alignment: .center, spacing: 18))
                layout {
                    cover.frame(width: coverHeight * 2 / 3, height: coverHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: wide ? .leading : .center, spacing: 16) {
                        Text(title).font(.title2.bold()).multilineTextAlignment(wide ? .leading : .center)
                            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                        status
                        IridiumLaunchMemoryView().frame(maxWidth: 440)
                        actions
                    }.frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity, minHeight: height)
                .padding(.leading, insets.leading + 24).padding(.trailing, insets.trailing + 24)
                .padding(.top, insets.top + 24).padding(.bottom, insets.bottom + 24)
            }.scrollBounceBehavior(.basedOnSize)
        }.foregroundStyle(.white).accessibilityIdentifier("gameLoadingScreen")
    }
}

/// Keep the last player view above the library while its first frame is laid out.
@MainActor enum IridiumPlayerTransition {
    private static var window: UIWindow?
    static func returnToLibrary() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let source = scene.windows.first(where: \.isKeyWindow),
              let snapshot = source.snapshotView(afterScreenUpdates: false) else { return }
        let overlay = UIWindow(windowScene: scene)
        overlay.frame = scene.coordinateSpace.bounds
        overlay.windowLevel = .alert + 1
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        snapshot.frame = controller.view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(snapshot)
        overlay.rootViewController = controller
        overlay.isUserInteractionEnabled = false
        overlay.isHidden = false
        window = overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.1 : 0.25, animations: {
                overlay.alpha = 0
            }, completion: { _ in
                overlay.isHidden = true
                if window === overlay { window = nil }
            })
        }
    }
}
