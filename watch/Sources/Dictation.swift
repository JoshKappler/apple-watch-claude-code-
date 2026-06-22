//
//  Dictation.swift
//  Apple's SYSTEM dictation — the Messages-style dictation — presented programmatically.
//
//  This is the load-bearing piece for the Action button: SwiftUI's TextFieldLink/TextField
//  can only open on a user tap, but `presentTextInputController` (WatchKit, NOT deprecated)
//  can be invoked from code and reached from a SwiftUI app via
//  `WKApplication.shared().visibleInterfaceController`. On watchOS 11+ the input screen
//  reopens to the last-used method, so a habitual dictation user lands straight in the live
//  mic — zero taps after the screen appears. SFSpeechRecognizer does NOT work on watchOS;
//  this system path is the real one.
//
//  Note: dictation does not work in the watchOS Simulator — test on a physical Ultra.
//

import WatchKit

enum Dictation {
    /// Present system text input (biased to dictation) and deliver the entered text on the
    /// main actor. No-ops silently if the user cancels.
    @MainActor
    static func present(completion: @escaping (String) -> Void) {
        present(attempt: 0, completion: completion)
    }

    @MainActor
    private static func present(attempt: Int, completion: @escaping (String) -> Void) {
        guard let controller = WKApplication.shared().visibleInterfaceController else {
            // The hosting controller can be nil for a moment during a cold (Action-button)
            // launch — retry a few times before giving up.
            guard attempt < 5 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                present(attempt: attempt + 1, completion: completion)
            }
            return
        }
        // nil suggestions + .plain biases toward the dictation flow (no suggestion list).
        controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
            guard let text = results?.first as? String, !text.isEmpty else { return }
            // Apply the result on the main actor IMMEDIATELY. The WatchKit completion already
            // fires on the main thread, so we run it inline via assumeIsolated rather than hopping
            // through `Task { @MainActor in … }`. That hop deferred the draft update behind the
            // reconnect work that scenePhase → .active kicks off the instant the dictation screen
            // closes, which showed up as a multi-second delay before the dictated text appeared.
            if Thread.isMainThread {
                MainActor.assumeIsolated { completion(text) }
            } else {
                DispatchQueue.main.async { completion(text) }
            }
        }
    }
}
