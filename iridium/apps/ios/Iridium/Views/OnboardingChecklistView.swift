import IridiumCore
import SwiftUI

struct OnboardingChecklistView: View {
    let checks: [OnboardingCheck]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Onboarding", systemImage: "checklist")
                .font(.headline)

            ForEach(checks) { check in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(for: check.state))
                        .font(.headline)
                        .foregroundStyle(color(for: check.state))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(check.title)
                            .font(.subheadline.weight(.semibold))
                        Text(check.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func symbol(for state: OnboardingCheckState) -> String {
        switch state {
        case .ready:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .actionRequired:
            "xmark.circle.fill"
        }
    }

    private func color(for state: OnboardingCheckState) -> Color {
        switch state {
        case .ready:
            .green
        case .warning:
            .orange
        case .actionRequired:
            .red
        }
    }
}
