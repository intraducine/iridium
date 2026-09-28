import SwiftUI

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
