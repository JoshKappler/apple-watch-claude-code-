//
//  DictationIntent.swift
//  The Action button → dictation bridge.
//
//  The Ultra's Action button can't bind to an arbitrary app action directly (that path is
//  gated to workout/dive intents), but it CAN be assigned to a Shortcut, and a Shortcut can
//  run an App Intent. So we expose `StartDictationIntent` as an App Shortcut: the user makes
//  a one-time assignment (Settings → Action Button → Shortcut → "Speak a message in Pinch"),
//  and from then on a press opens Pinch straight into the dictation mic.
//
//  Mechanism: the intent opens the app and bumps a flag on DictationRouter; PinchApp observes
//  it (onAppear for cold launch, onChange for warm) and calls Dictation.present(). See
//  Dictation.swift and PinchApp.swift.
//

import AppIntents
import SwiftUI

/// Shared signal between the App Intent (which runs at launch) and the SwiftUI app.
@MainActor
final class DictationRouter: ObservableObject {
    static let shared = DictationRouter()
    private init() {}

    /// Set true by the intent; PinchApp consumes it and resets it.
    @Published var shouldStartDictation = false
}

struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Speak a message"
    static var description = IntentDescription("Open Pinch and start dictating a message to the agent.")

    // Foreground the app so it can present the dictation UI.
    // watchOS 26 SDK supersedes this with `static var supportedModes: IntentModes = .foreground`;
    // `openAppWhenRun` still works and keeps us compatible with watchOS 11+.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DictationRouter.shared.shouldStartDictation = true
        return .result()
    }
}

/// Makes the intent discoverable in the Shortcuts app so it can be assigned to the Action button.
struct PinchAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Speak a message in \(.applicationName)",
                "Dictate in \(.applicationName)"
            ],
            shortTitle: "Speak a message",
            systemImageName: "mic.fill"
        )
    }
}
