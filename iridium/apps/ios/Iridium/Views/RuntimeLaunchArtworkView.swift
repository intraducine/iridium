import SwiftUI

/// A continuation of the library, above the live renderer until its first frame.
/// This owns visual emphasis only; session/readiness state remains in the player.
@MainActor struct RuntimeLaunchArtworkView: View {
    let session: RuntimePlayerSession
    let phase: RuntimeLaunchPresentation
    let safeInsets: EdgeInsets
    let viewLogs: () -> Void
    let close: () -> Void
    @State private var artwork: RuntimeLaunchArtworkSnapshot
    @State private var emphasized: Bool
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
        _emphasized = State(initialValue: phase != .starting)
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let compact = geometry.size.width > geometry.size.height && !typeSize.isAccessibilitySize
            let sourceTitle = artwork.retainedFrame(artwork.titleFrame, in: bounds)
            let left = max(safeInsets.leading + 8, sourceTitle?.minX ?? (safeInsets.leading + (compact ? 32 : 24)))
            let top = max(safeInsets.top + 8, sourceTitle?.minY ?? (safeInsets.top + (compact ? 72 : 112)))
            let right = safeInsets.trailing + (compact ? 32 : 24)
            ZStack(alignment: .topLeading) {
                Color.black
                backdrop(in: bounds)
                ScrollView {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, left).padding(.trailing, right)
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.top, min(top, max(safeInsets.top + 72, geometry.size.height * 0.45)))
                .padding(.bottom, safeInsets.bottom + 24)
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .task(id: session.sessionIdentifier) {
                // Once per mounted launch; opening Logs or rotating never replays the push.
                guard !emphasized else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.16 : RuntimeLaunchMotion.backdropDuration)) {
                    emphasized = true
                }
            }
        }
        .accessibilityIdentifier("playerLaunchArtwork")
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
        return Group {
            if let background = artwork.background {
                LibraryBackdrop(image: background, isLoading: false, position: artwork.backgroundY, reduceMotion: true)
            } else if let cover = artwork.cover {
                ArtworkImage(image: cover, title: "", position: artwork.coverY).blur(radius: 16)
            } else {
                Color.black
            }
        }
        .frame(width: frame.width, height: frame.height)
        .scaleEffect(RuntimeLaunchMotion.scale(emphasized: emphasized, reduceMotion: reduceMotion))
        .overlay { LibraryBackdropScrim(strength: emphasized ? 0.85 : 1) }
        .position(x: frame.midX, y: frame.midY)
        .clipped()
        .accessibilityHidden(true)
    }
}
