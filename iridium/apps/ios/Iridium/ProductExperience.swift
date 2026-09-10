import Foundation

enum ProductActivationPhase: Equatable {
    case repairLiveContainer
    case restartAfterRepair
    case importGame
    case enableLaunching
    case resolveGameBlocker
    case playGame
    case reviewGame
}

struct ProductActivationContext: Equatable {
    var isHostedByLiveContainer: Bool
    var liveContainerConfigured: Bool
    var repairRequiresRestart: Bool
    var gameCount: Int
    var readyGameCount: Int
    var blockedGameCount: Int
    var launchSupportUnavailable: Bool
    var featuredGameTitle: String?
}

struct ProductActivationState: Equatable {
    var phase: ProductActivationPhase
    var eyebrow: String
    var title: String
    var summary: String
    var actionTitle: String
    var systemImage: String

    static func resolve(_ context: ProductActivationContext) -> ProductActivationState {
        if context.isHostedByLiveContainer && context.repairRequiresRestart {
            return ProductActivationState(
                phase: .restartAfterRepair,
                eyebrow: "Setup updated",
                title: "Restart Iridium",
                summary: "Fully close Iridium, then open it again from LiveContainer so the repaired picker and launch settings can take effect.",
                actionTitle: "Check Setup Again",
                systemImage: "arrow.clockwise.circle.fill"
            )
        }

        if context.isHostedByLiveContainer && !context.liveContainerConfigured {
            return ProductActivationState(
                phase: .repairLiveContainer,
                eyebrow: "Step 1 of 3",
                title: "Prepare Iridium",
                summary: "Apply the LiveContainer settings Iridium needs to import folders and request JIT when launching games.",
                actionTitle: "Fix LiveContainer Setup",
                systemImage: "wrench.and.screwdriver.fill"
            )
        }

        if context.gameCount == 0 {
            return ProductActivationState(
                phase: .importGame,
                eyebrow: "Step 2 of 3",
                title: "Import your first game",
                summary: "Choose a Windows game folder. Iridium will scan it, recommend the launchable executable, and keep the original folder intact.",
                actionTitle: "Choose Game Folder",
                systemImage: "folder.badge.plus"
            )
        }

        if context.launchSupportUnavailable {
            return ProductActivationState(
                phase: .enableLaunching,
                eyebrow: "Launch support needed",
                title: "Enable launching",
                summary: "Your library is safe and ready to manage. Reconnect JIT for this Iridium process before starting a Windows game.",
                actionTitle: "Check Launch Support",
                systemImage: "bolt.badge.exclamationmark.fill"
            )
        }

        let gameTitle = context.featuredGameTitle ?? "your game"
        if context.blockedGameCount > 0 {
            return ProductActivationState(
                phase: .resolveGameBlocker,
                eyebrow: "One step left",
                title: "Finish setting up \(gameTitle)",
                summary: "Review the specific launch blocker and Iridium's recommended recovery action.",
                actionTitle: "Review \(gameTitle)",
                systemImage: "checklist"
            )
        }

        if context.readyGameCount > 0 {
            return ProductActivationState(
                phase: .playGame,
                eyebrow: "Ready to play",
                title: gameTitle,
                summary: "Launch support and the game environment are ready for a direct start.",
                actionTitle: "Play",
                systemImage: "play.fill"
            )
        }

        return ProductActivationState(
            phase: .reviewGame,
            eyebrow: "Game imported",
            title: gameTitle,
            summary: "Check compatibility and finish any remaining preparation before the first launch.",
            actionTitle: "Review \(gameTitle)",
            systemImage: "gamecontroller.fill"
        )
    }
}
