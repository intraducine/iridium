import SwiftUI

/// Keeps the library artwork on screen until the renderer presents a frame.
@MainActor struct RuntimeLaunchArtworkView: View {
    let session: RuntimePlayerSession
    let phase: RuntimeLaunchPresentation
    let safeInsets: EdgeInsets
    let viewLogs: () -> Void
    let close: () -> Void
    @State private var artwork: RuntimeLaunchArtworkSnapshot
    @ObservedObject var motionState: RuntimeLaunchMotionState
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: RuntimePlayerSession, phase: RuntimeLaunchPresentation, safeInsets: EdgeInsets,
         artwork: RuntimeLaunchArtworkSnapshot? = nil,
         motionState: RuntimeLaunchMotionState,
         viewLogs: @escaping () -> Void, close: @escaping () -> Void) {
        self.session = session
        self.phase = phase
        self.safeInsets = safeInsets
        self.viewLogs = viewLogs
        self.close = close
        self.motionState = motionState
        if let artwork, artwork.gameID == session.gameID {
            _artwork = State(initialValue: artwork)
        } else {
            _artwork = State(initialValue: .capture(session: session))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let landscape = bounds.width > bounds.height && !typeSize.isAccessibilitySize
            let top = max(safeInsets.top + (landscape ? 52 : 36), landscape ? bounds.height * 0.18 : 0)
            let leading = safeInsets.leading + (landscape ? 32 : 24)
            let trailing = safeInsets.trailing + (landscape ? 32 : 24)
            let coverWidth = landscape
                ? min(210, max(120, (bounds.height - top - safeInsets.bottom - 24) * 2 / 3))
                : min(190, bounds.width * 0.48)
            let coverHeight = coverWidth * 1.5
            let motion = !reduceMotion && !typeSize.isAccessibilitySize && !motionState.settled
            let sourceTitle = artwork.retainedFrame(artwork.titleFrame, in: bounds)
            let sourceCover = artwork.retainedFrame(artwork.coverFrame, in: bounds)

            ZStack(alignment: .topLeading) {
                Color.black
                backdrop(in: bounds)
                ScrollView {
                    Group {
                        if landscape, let cover = artwork.cover {
                            HStack(alignment: .top, spacing: 24) {
                                movingCover(cover, width: coverWidth, height: coverHeight,
                                            source: sourceCover, motion: motion)
                                VStack(alignment: .leading, spacing: 10) {
                                    movingTitle(landscape: true, source: sourceTitle, motion: motion)
                                    launchDetails()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                movingTitle(landscape: false, source: sourceTitle, motion: motion)
                                if let cover = artwork.cover {
                                    movingCover(cover, width: coverWidth, height: coverHeight,
                                                source: sourceCover, motion: motion)
                                        .frame(maxWidth: .infinity)
                                }
                                launchDetails()
                            }
                        }
                    }
                    .padding(.leading, leading).padding(.trailing, trailing)
                    .padding(.top, top)
                    .padding(.bottom, safeInsets.bottom + 24)
                    .frame(minHeight: bounds.height, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .coordinateSpace(name: "launchWindow")
            .foregroundStyle(.white)
        }
        .accessibilityIdentifier("playerLaunchArtwork")
    }

    private func movingTitle(landscape: Bool, source: CGRect?, motion: Bool) -> some View {
        Text(artwork.title)
            .font(landscape ? .title2.bold() : .largeTitle.bold())
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .visualEffect { content, geometry in
                let target = geometry.frame(in: .named("launchWindow"))
                let start = source ?? target
                return content.offset(x: motion ? start.minX - target.minX : 0,
                                      y: motion ? start.minY - target.minY : 0)
            }
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("playerLaunchTitle")
    }

    private func movingCover(_ cover: UIImage, width: CGFloat, height: CGFloat,
                             source: CGRect?, motion: Bool) -> some View {
        ArtworkImage(image: cover, title: "", position: artwork.coverY, fit: artwork.coverFits)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .visualEffect { content, geometry in
                let target = geometry.frame(in: .named("launchWindow"))
                let start = source ?? target
                return content.scaleEffect(x: motion ? start.width / max(1, target.width) : 1,
                                           y: motion ? start.height / max(1, target.height) : 1,
                                           anchor: .topLeading)
                    .offset(x: motion ? start.minX - target.minX : 0,
                            y: motion ? start.minY - target.minY : 0)
            }
            .accessibilityIdentifier("playerLaunchCover")
    }

    private func launchDetails() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(phase == .starting ? "Starting…" : phase.title)
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("playerLaunchStatus")
            }
            .opacity(motionState.detailsVisible ? 1 : 0)
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
        return Group {
            if let background = artwork.background {
                LibraryBackdrop(image: background, isLoading: false, position: artwork.backgroundY, reduceMotion: true)
            } else {
                Color.black
            }
        }
        .frame(width: frame.width, height: frame.height)
        .overlay { LibraryBackdropScrim() }
        .position(x: frame.midX, y: frame.midY)
        .clipped()
        .accessibilityHidden(true)
    }
}
