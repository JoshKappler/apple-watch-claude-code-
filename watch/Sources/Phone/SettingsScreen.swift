//
//  SettingsScreen.swift
//  Cleanly hidden settings — a gear opens this sheet. Pairing, connection, model/effort,
//  permission mode, audio, and context controls. Mirrors the watch's Settings but uses
//  native iOS controls (SecureField for the token, Pickers, a Form).
//

import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var store: PinchStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("pinch.serverURL") private var serverURL = ""
    @AppStorage("pinch.token") private var token = ""

    @State private var confirmBypass = false
    @State private var confirmClearContext = false

    var body: some View {
        NavigationStack {
            Form {
                pairingSection
                connectionSection
                modelSection
                modeSection
                audioSection
                contextSection
                buildSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Skip all permissions?",
                                isPresented: $confirmBypass, titleVisibility: .visible) {
                Button("Skip permissions (dangerous)", role: .destructive) {
                    store.setMode(.bypassPermissions)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The agent will run commands and edit files with no further approvals.")
            }
            .confirmationDialog("Clear context?",
                                isPresented: $confirmClearContext, titleVisibility: .visible) {
                Button("Clear context", role: .destructive) { store.clearContext() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Starts a fresh agent session — the current conversation's context is dropped.")
            }
        }
    }

    // MARK: - Sections

    private var pairingSection: some View {
        Section {
            HStack {
                Text("Server")
                Spacer()
                TextField("wss://your-tunnel", text: $serverURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Token")
                Spacer()
                SecureField("PINCH_TOKEN", text: $token)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
            Button("Reset to baked default") {
                serverURL = Secrets.serverURL
                token = Secrets.token
            }
            .font(.footnote)
        } header: {
            Text("Pairing")
        } footer: {
            Text("The token is an RCE-grade password. It must match PINCH_TOKEN in the backend's .env exactly.")
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Status", value: connectionText)
            if let sid = store.sessionId {
                LabeledContent("Session", value: String(sid.prefix(12)))
            }
            if let project = store.currentProject {
                LabeledContent("Project", value: project.name)
            }
            Button("Reconnect") { store.reconnect() }
            Button("Restart backend", role: .destructive) { store.restartBackend() }
        }
    }

    private var modelSection: some View {
        Section("Model") {
            Picker("Model", selection: $store.selectedModel) {
                ForEach(PinchStore.availableModels) { m in
                    Text(m.label).tag(m.id)
                }
            }
            Picker("Effort", selection: $store.thinkingLevel) {
                ForEach(ThinkingLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
        }
    }

    private var modeSection: some View {
        Section {
            ForEach(PermissionMode.allCases) { m in
                Button {
                    if m == .bypassPermissions {
                        confirmBypass = true
                    } else {
                        store.setMode(m)
                    }
                } label: {
                    HStack {
                        Label(m.label, systemImage: m.symbol)
                            .foregroundStyle(.primary)
                        Spacer()
                        if store.mode == m {
                            Image(systemName: "checkmark").foregroundStyle(PinchTheme.accent)
                        }
                    }
                }
            }
        } header: {
            Text("Permission mode")
        } footer: {
            Text(store.mode.blurb)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Speak replies", isOn: $store.ttsEnabled)
                .tint(PinchTheme.accent)
        }
    }

    private var contextSection: some View {
        Section("Context") {
            Button("Compact context") { store.compactContext() }
            Button("Clear context", role: .destructive) { confirmClearContext = true }
            Button("Clear transcript") { store.clearTranscript() }
        }
    }

    // The git SHA + time baked into THIS binary at compile time. If it doesn't change after a
    // reinstall, the new code never landed — match it against what the flash prints.
    private var buildSection: some View {
        Section("Build") {
            LabeledContent("Stamp") {
                Text(BuildStamp.value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var connectionText: String {
        switch store.connection {
        case .connected, .ready: return "Connected"
        case .connecting:        return "Connecting"
        case .reconnecting:      return "Reconnecting"
        case .disconnected:      return "Offline"
        case .failed(let m):     return m
        }
    }
}
