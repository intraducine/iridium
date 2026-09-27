import SwiftUI

/// A moving poster/title over an unchanged library backdrop. The player still owns
/// first-frame readiness and fades this entire view, not its individual elements.
@MainActor struct RuntimeLaunchArtworkView: View {
    let session: RuntimePlayerSession
    let phase: RuntimeLaunchPresentation
    let safeInsets: EdgeInsets
    let viewLogs: () -> Void
    let close: () -> Void
    @State private var artwork: RuntimeLaunchArtworkSnapshot
    @State private var settled: Bool
    @State private var textHeight: CGFloat = 100
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: RuntimePlayerSession, phase: RuntimeLaunchPresentation, safeInsets: EdgeInsets,
         artwork: RuntimeLaunchArtworkSnapshot? = nil,
         viewLogs: @escaping () -> Void, close: @escaping () -> Void) {
        self.session = session
        self.phase = phase
        self.safeInsets = safeInsets
        self.viewLogs = viewLogs
        self.close = close
        if let artwork, artwork.gameID == session.gameID {
            _artwork = State(initialValue: artwork)
        } else {
            _artwork = State(initialValue: .capture(session: session))
        }
        _settled = State(initialValue: phase != .starting)
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let layout = RuntimeLaunchHeroLayout.resolve(in: bounds, safeTop: safeInsets.top,
                safeLeading: safeInsets.leading, safeBottom: safeInsets.bottom, safeTrailing: safeInsets.trailing,
                hasCover: artwork.cover != nil, accessibility: typeSize.isAccessibilitySize, textHeight: textHeight)
            let moving = !settled && !reduceMotion
            let coverFrame = moving ? (artwork.retainedFrame(artwork.coverFrame, in: bounds) ?? layout.cover) : layout.cover
            let textFrame = moving ? (artwork.retainedFrame(artwork.titleFrame, in: bounds) ?? layout.text) : layout.text
            let compact = bounds.width > bounds.height && !typeSize.isAccessibilitySize
            ZStack(alignment: .topLeading) {
                Color.black
                backdrop(in: bounds)
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        if let cover = artwork.cover, let frame = coverFrame {
                            ArtworkImage(image: cover, title: "", position: artwork.coverY, fit: !artwork.customCover)
                                .frame(width: frame.width, height: frame.height)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .offset(x: frame.minX, y: frame.minY)
                                .accessibilityElement(children: .ignore)
                                .accessibilityHidden(false)
                                .accessibilityLabel("\(artwork.title) artwork")
                                .accessibilityIdentifier("playerLaunchCover")
                        }
                        textColumn(compact: compact)
                            .frame(width: textFrame.width, alignment: .leading)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                            .offset(x: textFrame.minX, y: textFrame.minY)
                    }
                    .frame(width: bounds.width,
                           height: max(bounds.height, max(coverFrame?.maxY ?? 0, textFrame.minY + textHeight) + safeInsets.bottom + 24),
                           alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .onReceive(artwork.handoff.$chromeHidden) { hidden in
                guard hidden, !settled, !artwork.handoff.hasPresentedFrame else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: RuntimeLaunchMotion.heroDuration)) {
                    settled = true
                }
            }
        }
        .accessibilityIdentifier("playerLaunchArtwork")
    }

    private func textColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            Text(artwork.title)
                .font(compact ? .title2.bold() : .largeTitle.bold())
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("playerLaunchTitle")
            HStack(spacing: 10) {
                if phase.isBusy {
                    ProgressView().controlSize(.small).tint(.white).accessibilityHidden(true)
                }
                Text(phase == .starting ? "Starting…" : phase.title)
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("playerLaunchStatus")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("playerLaunchPanel")
            if let message = phase.message {
                Text(message).font(.callout).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !phase.isBusy && phase != .playing {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { recoveryActions }
                    VStack(alignment: .leading, spacing: 12) { recoveryActions }
                }
                .padding(.top, 8)
            }
        }
    }

    private var recoveryActions: some View {
        Group {
            Button("View Logs", systemImage: "doc.text", action: viewLogs).libraryGlass(prominent: true)
            Button("Back to Library", action: close).libraryGlass()
        }
        .frame(minHeight: 44)
    }

    private func backdrop(in bounds: CGRect) -> some View {
        let frame = artwork.retainedFrame(artwork.backdropFrame, in: bounds) ?? bounds
        return LibraryBackdrop(image: artwork.background, isLoading: false,
                               position: artwork.backgroundY, reduceMotion: true)
            .frame(width: frame.width, height: frame.height)
            .overlay { LibraryBackdropScrim() }
            .position(x: frame.midX, y: frame.midY)
            .clipped()
            .accessibilityHidden(true)
    }
}
