import SwiftUI

/// Artwork stays above the live render surface until that surface presents a frame.
/// This view never inspects logs, fetches network artwork, or starts the runtime.
struct RuntimeLaunchArtworkView: View {
    let session: RuntimePlayerSession
    let phase: RuntimeLaunchPresentation
    let safeInsets: EdgeInsets
    let viewLogs: () -> Void
    let close: () -> Void
    @ObservedObject private var artwork = LibraryArtwork.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let appearance = artwork.appearance(session.gameID)
        let background = artwork.displayImage(appearance.background)
        let cover = artwork.displayImage(appearance.cover)
        GeometryReader { geometry in
            let compact = geometry.size.width > geometry.size.height && !typeSize.isAccessibilitySize
            let top = safeInsets.top + 72
            let bottom = safeInsets.bottom + 20
            ZStack {
                Color.black
                if let background {
                    ArtworkImage(image: background, title: "", position: appearance.backgroundY)
                } else if let cover {
                    ArtworkImage(image: cover, title: "", position: appearance.coverY)
                        .blur(radius: 16)
                }
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.35), .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
                ScrollView {
                    VStack(spacing: compact ? 12 : 20) {
                        if let cover {
                            ArtworkImage(image: cover, title: "", position: appearance.coverY,
                                         fit: !appearance.customCover)
                                .frame(width: compact ? 64 : 112, height: compact ? 96 : 168)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                        } else {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: compact ? 40 : 64))
                                .accessibilityHidden(true)
                        }
                        Text(appearance.title ?? appearance.matchName ?? session.gameTitle)
                            .font(compact ? .title2.bold() : .largeTitle.bold())
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 10) {
                            if phase.isBusy {
                                ProgressView().tint(.white).accessibilityHidden(true)
                            }
                            Text(phase.title).font(.headline)
                                .accessibilityIdentifier("playerLaunchStatus")
                            if let message = phase.message {
                                Text(message).font(.callout).foregroundStyle(.white.opacity(0.85))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("playerLaunchPanel")
                        if phase == .starting {
                            Button("Cancel launch", action: close)
                                .buttonStyle(.bordered).tint(.white)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("cancelGameLaunch")
                        } else if !phase.isBusy {
                            VStack(spacing: 8) {
                                Button("View Logs", systemImage: "doc.text", action: viewLogs)
                                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                                Button("Back to Library", action: close)
                                    .buttonStyle(.bordered).tint(.white)
                            }
                            .controlSize(.large)
                        }
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, max(24, max(safeInsets.leading, safeInsets.trailing) + 16))
                    .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - top - bottom))
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.top, top)
                .padding(.bottom, bottom)
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.25), value: background != nil)
        }
        .accessibilityIdentifier("playerLaunchArtwork")
    }
}
