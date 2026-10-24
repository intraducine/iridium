// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

@MainActor final class IridiumGameAudio: ObservableObject {
    static let shared = IridiumGameAudio()
    @Published private(set) var volume = 1.0
    private var game: UUID?
    func begin(_ game: UUID, legacyMuted: Bool = false) {
        ir_audio_volume_bind(nil, nil)
        self.game = game
        volume = IridiumGameVolume.load(game, legacyMuted: legacyMuted)
        ir_audio_volume_set(Float(volume))
    }
    func setVolume(_ value: Double) {
        volume = IridiumGameVolume.clamp(value)
        if let game { IridiumGameVolume.save(volume, game: game) }
        ir_audio_volume_set(Float(volume))
    }
    func adjust(_ command: String) {
        setVolume(volume + (command == "left" ? -0.05 : 0.05))
    }
}

struct IridiumGameVolumeSlider: View {
    @ObservedObject private var audio = IridiumGameAudio.shared
    var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Volume")
                Spacer()
                Text("\(Int((audio.volume * 100).rounded()))%").monospacedDigit()
            }
            Slider(value: Binding(get: { audio.volume }, set: audio.setVolume), in: 0...1, step: 0.01)
                .frame(minHeight: 44)
                .accessibilityLabel("Game volume")
                .accessibilityValue("\(Int((audio.volume * 100).rounded())) percent")
        }.padding(12)
            .background(selected ? Color.white.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
            .id("Volume")
    }
}
