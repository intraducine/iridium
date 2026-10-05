import ActivityKit
import SwiftUI
import WidgetKit
import UIKit
import ImageIO

#if !IRIDIUM_ACTIVITY_RENDERING
@main
struct SteamDownloadWidgetBundle: WidgetBundle {
    var body: some Widget { SteamDownloadWidget() }
}
#endif

struct SteamDownloadWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SteamDownloadActivityAttributes.self) { context in
            SteamDownloadCard(context: .init(context))
                .activityBackgroundTint(Color(white: 0.07))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SteamDownloadSymbol(context: .init(context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SteamDownloadPercent(context: .init(context)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) { SteamDownloadCard(context: .init(context), expandedIsland: true) }
            } compactLeading: {
                SteamDownloadSymbol(context: .init(context))
            } compactTrailing: {
                SteamDownloadRing(context: .init(context))
            } minimal: {
                SteamDownloadRing(context: .init(context))
            }
            .keylineTint(.white.opacity(0.7))
        }
    }
}

struct SteamDownloadViewData {
    let attributes: SteamDownloadActivityAttributes
    let state: SteamDownloadActivityAttributes.ContentState
    let isStale: Bool
    init(_ context: ActivityViewContext<SteamDownloadActivityAttributes>) {
        attributes = context.attributes; state = context.state; isStale = context.isStale
    }
    init(attributes: SteamDownloadActivityAttributes, state: SteamDownloadActivityAttributes.ContentState, isStale: Bool) {
        self.attributes = attributes; self.state = state; self.isStale = isStale
    }
    var presentation: SteamDownloadPresentation {
        .init(phase: state.phase, verifiedBytes: state.verifiedBytes, totalBytes: state.totalBytes, isStale: isStale,
              receivedBytesPerSecond: state.receivedBytesPerSecond)
    }
    var phaseLabel: String { presentation.statusLabel }
    var spokenSummary: String {
        let phase = presentation.isStale ? "Open Iridium to refresh download status" : state.label
        let rate = presentation.receivedRateSummary.map { " Last observed received rate: \($0)." } ?? ""
        return "\(attributes.gameName). \(phase). \(presentation.verifiedSummary).\(rate)"
    }
}

struct SteamDownloadCard: View {
    let context: SteamDownloadViewData
    var expandedIsland = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: expandedIsland ? 4 : 8) {
            Text(context.attributes.gameName)
                .font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                .privacySensitive()
                .accessibilityLabel(context.attributes.gameName)
                .accessibilityAddTraits(.isHeader)
            SteamDownloadProgress(presentation: context.presentation)
            if typeSize.isAccessibilitySize {
                verifiedCount
                if let rate = context.presentation.receivedRateSummary { receivedRate(rate) }
                status
                if !context.state.isTerminal { cancel }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    verifiedCount
                    Spacer(minLength: 0)
                    if let rate = context.presentation.receivedRateSummary { receivedRate(rate) }
                }
                HStack(spacing: 8) {
                    status
                    Spacer(minLength: 0)
                    if !context.state.isTerminal { cancel }
                }
            }
        }
        .padding(.horizontal, expandedIsland ? 10 : 14)
        .padding(.vertical, expandedIsland ? 6 : 14)
        .foregroundStyle(.white)
        .background {
            GeometryReader { geometry in
                ZStack {
                    Color(white: 0.07)
                    if !reduceTransparency, let image = artworkImage {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: 3).opacity(luminanceReduced ? 0.25 : 0.85)
                        LinearGradient(colors: [.black.opacity(contrast == .increased ? 0.8 : 0.55),
                                                .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                    }
                }.clipped()
            }.accessibilityHidden(true).privacySensitive()
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var status: some View {
        Label(context.phaseLabel, systemImage: context.presentation.symbol)
            .font(.callout).foregroundStyle(SteamDownloadSymbol.color(context.presentation.tone, dimmed: luminanceReduced))
            .lineLimit(1).truncationMode(.tail)
            .accessibilityLabel(context.spokenSummary)
            .layoutPriority(1)
    }

    private var cancel: some View {
        Button(intent: CancelSteamDownloadIntent(operationId: context.attributes.operationId)) {
            Text("Cancel").font(.callout).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12).frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.1), in: Capsule())
        .contentShape(Rectangle())
        .accessibilityLabel("Cancel download for \(context.attributes.gameName)")
    }

    private var verifiedCount: some View {
        Text(context.presentation.verifiedAmount)
            .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85))
            .lineLimit(1).truncationMode(.tail)
            .accessibilityLabel(context.presentation.verifiedSummary)
    }

    private func receivedRate(_ rate: String) -> some View {
        Label(rate, systemImage: "arrow.down").font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Last observed received rate: \(rate)")
    }

    private var artworkImage: UIImage? {
        guard let data = context.state.artworkJPEG, data.count <= 1_450,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.intValue > 0, width.intValue <= 80, height.intValue > 0, height.intValue <= 40 else { return nil }
        return UIImage(data: data)
    }
}

struct SteamDownloadSymbol: View {
    let context: SteamDownloadViewData
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    var body: some View {
        Image(systemName: context.presentation.symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(Self.color(context.presentation.tone, dimmed: luminanceReduced))
            .accessibilityLabel(context.spokenSummary)
    }
    static func color(_ tone: SteamDownloadPresentation.Tone, dimmed: Bool) -> Color {
        if dimmed { return .white }
        switch tone {
        case .neutral: return .white
        case .success: return .green
        case .attention: return .orange
        case .failure: return .red
        }
    }
}

struct SteamDownloadPercent: View {
    let context: SteamDownloadViewData
    var body: some View {
        Group {
            if let fraction = context.presentation.fractionCompleted {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .accessibilityLabel("Verified \(fraction.formatted(.percent.precision(.fractionLength(0)))) of game files")
            } else {
                Text("—").accessibilityLabel("Total download size unknown")
            }
        }
        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
        .fixedSize()
    }
}

private struct SteamDownloadProgress: View {
    let presentation: SteamDownloadPresentation
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(contrast == .increased ? 0.45 : 0.18))
                if let fraction = presentation.fractionCompleted {
                    Capsule().fill(.white).frame(width: geometry.size.width * fraction)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

struct SteamDownloadRing: View {
    let context: SteamDownloadViewData
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            if context.presentation.tone != .neutral || context.state.isTerminal || context.presentation.fractionCompleted == nil {
                SteamDownloadSymbol(context: context)
            } else if let fraction = context.presentation.fractionCompleted {
                ZStack {
                    Circle().stroke(.white.opacity(contrast == .increased ? 0.5 : 0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: fraction).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 18, height: 18)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(context.spokenSummary)
    }
}
