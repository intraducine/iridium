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
            .font(.caption.monospacedDigit()).foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine).accessibilityIdentifier("launchMemoryStatus")
        }
    }
}
