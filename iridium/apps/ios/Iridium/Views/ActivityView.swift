import IridiumCore
import SwiftUI

struct ActivityView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Group {
            if viewModel.activityFeed.isEmpty
                && viewModel.launchHistory.isEmpty
                && viewModel.verificationAudits.isEmpty
            {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Imports, compatibility checks, repairs, and launches will appear here.")
                )
            } else {
                List {
                    if !viewModel.activityFeed.isEmpty {
                        Section("Recent") {
                            ForEach(viewModel.activityFeed) { entry in
                                activityRow(entry)
                            }
                        }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
                    }

                    if !viewModel.launchHistory.isEmpty {
                        Section("Launches") {
                            ForEach(viewModel.launchHistory) { entry in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(entry.gameTitle)
                                            .font(.headline)
                                        Spacer()
                                        Text(entry.readiness)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let failureReason = entry.failureReason {
                                        Label(failureReason, systemImage: "exclamationmark.triangle.fill")
                                            .font(.footnote)
                                            .foregroundStyle(.red)
                                    }
                                    Text(entry.launchedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                        }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
                    }

                    if !viewModel.verificationAudits.isEmpty {
                        Section("Compatibility Checks") {
                            ForEach(viewModel.verificationAudits) { audit in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(audit.gameTitle)
                                            .font(.headline)
                                        Spacer()
                                        auditStatus(audit.overallStatus)
                                    }
                                    Text(audit.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Text(audit.verifiedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                        }.listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).padding(.vertical, 2)).listRowSeparator(.hidden)
                    }
                }
                .iridiumListChrome()
            }
        }.iridiumPageSurface().navigationTitle("Activity")
    }

    private func activityRow(_ entry: ActivityLogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: entry.kind))
                .font(.body.weight(.semibold))
                .foregroundStyle(color(for: entry.kind))
                .frame(width: 34, height: 34)

                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.headline)
                Text(entry.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func auditStatus(_ status: VerificationAuditStatus) -> some View {
        switch status {
        case .ready:
            IridiumStatusPill(title: "Ready", systemImage: "checkmark.circle.fill", tone: .green)
        case .warning:
            IridiumStatusPill(title: "Warning", systemImage: "exclamationmark.triangle.fill", tone: .orange)
        case .blocked:
            IridiumStatusPill(title: "Blocked", systemImage: "xmark.octagon.fill", tone: .red)
        }
    }

    private func icon(for kind: ActivityLogKind) -> String {
        switch kind {
        case .imported, .steamRegistered:
            "square.and.arrow.down.fill"
        case .stagedReset, .uninstalled:
            "trash.fill"
        case .prefixRepairScheduled, .prefixRebuilt:
            "wrench.and.screwdriver.fill"
        case .runtimeValidated:
            "checkmark.shield.fill"
        case .launchQueuedForJIT:
            "hourglass"
        case .launchResumed:
            "play.fill"
        case .launchResumeFailed:
            "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: ActivityLogKind) -> Color {
        switch kind {
        case .launchResumeFailed, .uninstalled:
            .red
        case .launchQueuedForJIT, .prefixRepairScheduled:
            .orange
        case .launchResumed, .runtimeValidated, .prefixRebuilt:
            .green
        case .imported, .steamRegistered, .stagedReset:
            .blue
        }
    }
}
