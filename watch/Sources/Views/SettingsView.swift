//
//  SettingsView.swift
//  Pairing + preferences. Server URL and token persist via @AppStorage; the speaker
//  toggle controls TTS readback; and we show a double-tap availability readout so you
//  know whether the hardware Send gesture is active on this watch.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PinchStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("pinch.serverURL") private var serverURL = ""
    @AppStorage("pinch.token") private var token = ""

    @State private var confirmBypass = false

    var body: some View {
        List {
            // Permission mode — moved here from the bottom bar. Each row calls store.setMode.
            // bypassPermissions keeps the RED styling + a guarded confirmation alert.
            Section("Permission mode") {
                ForEach(PermissionMode.allCases) { m in
                    Button {
                        if m == .bypassPermissions {
                            confirmBypass = true        // guarded — don't apply yet
                        } else {
                            store.setMode(m)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: m.symbol)
                                .font(.system(size: 13))
                                .foregroundStyle(m == .bypassPermissions ? .red : .primary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.label)
                                    .font(.system(size: 14, weight: store.mode == m ? .semibold : .regular))
                                    .foregroundStyle(m == .bypassPermissions ? .red : .primary)
                                Text(m.blurb)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if store.mode == m {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(m == .bypassPermissions ? .red : Color.pinch)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Model + thinking level — bound straight to the store's @Published vars. The state
            // layer persists these and pushes the config to the backend; the UI only sets them.
            Section("Model") {
                Picker("Model", selection: $store.selectedModel) {
                    ForEach(PinchStore.availableModels, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .pickerStyle(.navigationLink)

                Picker("Thinking", selection: $store.thinkingLevel) {
                    ForEach(ThinkingLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.navigationLink)

                Text("Higher thinking levels let the agent reason longer before answering. Off is fastest.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("Pairing") {
                // Watch TextFields invoke dictation/scribble; paste from the paired phone also works.
                // Plain TextFields (NOT SecureField) so watchOS doesn't pop the saved-passwords
                // AutoFill sheet — pairing is baked in, the user never types these.
                TextField("Server URL", text: $serverURL)
                    .font(.system(size: 13))
                    .textContentType(.URL)
                TextField("Pairing token", text: $token)
                    .font(.system(size: 13))
                    .textContentType(.none)
                Text("e.g. wss://pinch.yourdomain.com — the backend's public URL. Token is the PINCH_TOKEN you set in the backend .env.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                LabeledContent("Status") {
                    Text(statusText).foregroundStyle(statusColor)
                }
                if let session = store.sessionId {
                    LabeledContent("Session") {
                        Text(session).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    }
                }
                if let project = store.currentProject {
                    LabeledContent("Project") { Text(project.name) }
                }
                Button("Reconnect now") { store.reconnect() }
                    .disabled(!store.canConnect)
            }

            Section("Audio") {
                // TTS readback — bound to the store's @Published flag (the state layer persists it
                // and decides whether to speak). Replaces the old @AppStorage speakerMuted toggle.
                Toggle("Speak replies", isOn: $store.ttsEnabled)
                    .tint(.pinch)
                Text("Watch TTS can be silent without AirPods/Bluetooth audio. A haptic always fires regardless, so you still feel each reply.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("Gestures") {
                LabeledContent("Double pinch to send") {
                    Label(DoubleTap.statusLabel, systemImage: DoubleTap.isAvailable ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(DoubleTap.isAvailable ? .green : .secondary)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12))
                }
                Text(DoubleTap.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Wrist-shake cancels an in-flight turn. Digital Crown scrolls the transcript and diffs.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear transcript", role: .destructive) {
                    store.clearTranscript()
                    dismiss()
                }
            }
        }
        .navigationTitle("Settings")
        .alert("Skip all permissions?", isPresented: $confirmBypass) {
            Button("Cancel", role: .cancel) { }
            Button("Skip permissions", role: .destructive) {
                store.setMode(.bypassPermissions)
                Haptics.failure()   // deliberately alarming feedback.
            }
        } message: {
            Text("The agent will run edits and commands with NO approvals. It can modify and delete files and run shell commands unattended. Only do this when you trust the task.")
        }
    }

    private var statusText: String {
        switch store.connection {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Authenticating…"
        case .ready: return "Connected"
        case .reconnecting(let n): return "Reconnecting (\(n))"
        case .failed(let m): return m
        }
    }
    private var statusColor: Color {
        switch store.connection {
        case .ready: return .green
        case .failed: return .red
        case .reconnecting, .connecting, .connected: return .orange
        case .disconnected: return .secondary
        }
    }
}

/// Feature-detection for the hardware double-tap (`.handGestureShortcut(.primaryAction)`).
///
/// There is no public boolean API that says "double-tap is active." It requires:
///   • watchOS 11+ (build-time / runtime guaranteed by our deployment target), AND
///   • Series 9 / Ultra 2 or later hardware (the Neural Engine + sensor support).
/// We can't read the exact model reliably from public API, so we report a best-effort
/// status: the OS supports the API, and double-tap will be live on supported hardware
/// with the system Double-Tap setting enabled. On older watches the on-screen Send works.
enum DoubleTap {
    /// The `.handGestureShortcut(.primaryAction)` API exists on watchOS 11+. We target 11,
    /// so this is always true at runtime here — the *hardware* gate is what varies.
    static var isAvailable: Bool {
        if #available(watchOS 11.0, *) { return true }
        return false
    }

    static var statusLabel: String { isAvailable ? "Supported" : "On-screen only" }

    static var detail: String {
        "Double pinch (Apple's Double Tap gesture — pinch index finger and thumb twice) requires Apple Watch Series 9 / Ultra 2 or later, with Double Tap enabled in Settings → Gestures. On older models, tap Send on screen."
    }
}
