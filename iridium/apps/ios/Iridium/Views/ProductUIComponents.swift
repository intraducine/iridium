import SwiftUI

struct IridiumHeroCard<Action: View>: View {
    let eyebrow: String
    let title: String
    let summary: String
    let systemImage: String
    let tone: Color
    @ViewBuilder let action: () -> Action
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if dynamicTypeSize.isAccessibilitySize {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tone)
                    .frame(width: 48, height: 48)
                    .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                heroCopy
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(tone)
                        .frame(width: 48, height: 48)
                        .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)

                    heroCopy
                }
            }

            action()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(tone.opacity(0.16), lineWidth: 1)
        }
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(tone)
                .tracking(0.6)
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct IridiumSectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let detail {
                Text(detail)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct IridiumGameArtwork: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.orange.opacity(0.92), .pink.opacity(0.68), .purple.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "gamecontroller.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.94))
        }
        .frame(width: 68, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
        .accessibilityLabel("Artwork placeholder for \(title)")
    }
}

struct IridiumStatusPill: View {
    let title: String
    let systemImage: String
    let tone: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tone.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct IridiumFeedbackBanner: View {
    let message: String
    var systemImage: String = "info.circle.fill"
    var tone: Color = .blue

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tone)
        }
        .font(.footnote.weight(.medium))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
