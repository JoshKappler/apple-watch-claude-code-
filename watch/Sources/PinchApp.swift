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
                    case .background, .inactive:
                        store.onBackground()
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
