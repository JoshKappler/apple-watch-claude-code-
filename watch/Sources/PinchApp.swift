//
//  PinchApp.swift
//  @main entry point. Owns the PinchStore and drives the connection off scenePhase
//  (foreground-only socket). A WKApplicationDelegate bridges APNs token callbacks
//  into PushRegistration.
//

import SwiftUI
import WatchKit

@main
struct PinchApp: App {
    @WKApplicationDelegateAdaptor(PinchAppDelegate.self) private var appDelegate
    @StateObject private var store = PinchStore()
    @StateObject private var dictationRouter = DictationRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    // Persisted settings — the single place the user configures server + token.
    @AppStorage("pinch.serverURL") private var serverURL = ""
    @AppStorage("pinch.token") private var token = ""
    @AppStorage("pinch.speakerMuted") private var speakerMuted = false

    init() {
        // Pre-fill pairing so there is NOTHING to type on the watch. The URL + token live in
        // Secrets.swift, which is GITIGNORED — the token is an RCE password and must never be
        // committed. Copy watch/Secrets.example.swift → watch/Sources/Secrets.swift (or run
        // ./setup.sh, which does it and injects PINCH_TOKEN from backend/.env).
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["pinch.serverURL": Secrets.serverURL, "pinch.token": Secrets.token])

        // TEMP (dev phase): the quick-tunnel URL changes between sessions, and a value an
        // earlier build wrote to UserDefaults would override register(defaults:) and strand the
        // watch on a DEAD old tunnel (symptom: "Connecting…" forever, nothing in the backend
        // log). Force the live values every launch so a stale stored URL can't do that. Remove
        // this force-write once we move to a permanent tunnel and let the user own the setting.
        defaults.set(Secrets.serverURL, forKey: "pinch.serverURL")
        defaults.set(Secrets.token, forKey: "pinch.token")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    appDelegate.push = store.push
                    store.configure(serverURL: serverURL, token: token, speakerMuted: speakerMuted)
                    consumeDictationRequest()   // cold launch via the Action button
                }
                // Action button (warm app) → start dictation.
                .onChange(of: dictationRouter.shouldStartDictation) { _, requested in
                    if requested { consumeDictationRequest() }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        store.configure(serverURL: serverURL, token: token, speakerMuted: speakerMuted)
                        store.onActive()
                    case .background:
                        // Only a REAL background (screen off / app suspended) drops the socket.
                        store.onBackground()
                    case .inactive:
                        // Transient (wrist tilt, Control Center, system overlay, launch flicker)
                        // — do NOT disconnect, or the socket gets torn down ~1s after dialing and
                        // never opens. Keep it alive across these blips.
                        break
                    @unknown default:
                        break
                    }
                }
                // Reconfigure live when the user edits settings.
                .onChange(of: serverURL) { _, _ in reconfigureAndReconnect() }
                .onChange(of: token) { _, _ in reconfigureAndReconnect() }
                .onChange(of: speakerMuted) { _, muted in store.speaker.setMuted(muted) }
        }
    }

    private func reconfigureAndReconnect() {
        if store.configure(serverURL: serverURL, token: token, speakerMuted: speakerMuted) {
            store.onActive()
        }
    }

    /// If the Action button asked us to dictate, present system dictation and fold the
    /// result into the draft. Handles both cold launch (onAppear) and warm (onChange).
    @MainActor
    private func consumeDictationRequest() {
        guard dictationRouter.shouldStartDictation else { return }
        dictationRouter.shouldStartDictation = false
        Dictation.present { store.appendDictated($0) }
    }
}

/// Bridges UIKit-less watchOS app-delegate callbacks (APNs) into our PushRegistration.
final class PinchAppDelegate: NSObject, WKApplicationDelegate {
    weak var push: PushRegistration?

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        Task { @MainActor in push?.didRegister(deviceToken: deviceToken) }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        Task { @MainActor in push?.didFailToRegister(error) }
    }
}
