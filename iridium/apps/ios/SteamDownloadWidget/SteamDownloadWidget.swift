import ActivityKit
import SwiftUI
import WidgetKit

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
                    HStack(spacing: 6) {
                        SteamDownloadSymbol(context: .init(context))
                        Text("Iridium").font(.caption.weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) { SteamDownloadPercent(context: .init(context)) }
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
        .init(phase: state.phase, verifiedBytes: state.verifiedBytes, totalBytes: state.totalBytes, isStale: isStale)
    }
    var phaseLabel: String { presentation.isStale ? "Open Iridium to refresh download status" : state.label }
    var spokenSummary: String { "\(attributes.gameName). \(phaseLabel). \(presentation.verifiedSummary)." }
}

struct SteamDownloadCard: View {
    let context: SteamDownloadViewData
    var expandedIsland = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !expandedIsland && !typeSize.isAccessibilitySize {
                HStack(spacing: 6) {
                    SteamDownloadSymbol(context: context)
                    Text("IRIDIUM").font(.caption2.weight(.semibold)).tracking(1)
                    Spacer()
                    Text("Steam Download").font(.caption2).foregroundStyle(.white.opacity(0.72))
                }
                .accessibilityHidden(true)
            }
            Text(context.attributes.gameName)
                .font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .privacySensitive()
                .accessibilityLabel(context.attributes.gameName)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .center, spacing: 8) {
                Label(context.phaseLabel, systemImage: context.presentation.symbol)
                    .font(.callout).foregroundStyle(SteamDownloadSymbol.color(context.presentation.tone, dimmed: luminanceReduced))
                    .lineLimit(2).layoutPriority(1)
                Spacer(minLength: 0)
                if !context.state.isTerminal {
                    Button(intent: CancelSteamDownloadIntent(operationId: context.attributes.operationId)) {
                        Text("Cancel").font(.callout.weight(.semibold)).frame(minHeight: 28)
                    }
                    .buttonStyle(.bordered).tint(.white)
                    .frame(minHeight: 44).contentShape(Rectangle())
                    .accessibilityLabel("Cancel download for \(context.attributes.gameName)")
                }
            }
            HStack(spacing: 10) {
                SteamDownloadProgress(presentation: context.presentation)
                if !expandedIsland, context.presentation.fractionCompleted != nil {
                    SteamDownloadPercent(context: context)
                }
            }
            ViewThatFits(in: .horizontal) {
                if !expandedIsland && !typeSize.isAccessibilitySize {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        verifiedCount.fixedSize()
                        Spacer(minLength: 0)
                        Text("Updated \(context.state.lastUpdated, style: .time)")
                            .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.65))
                            .fixedSize()
                    }
                }
                verifiedCount
            }
        }
        .padding(expandedIsland ? 0 : 14)
        .foregroundStyle(.white)
    }

    private var verifiedCount: some View {
        Text(context.presentation.verifiedSummary)
            .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(context.presentation.verifiedSummary)
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
