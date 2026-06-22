//
//  ComposerView.swift
//  Fixed bottom bar (NOT inside a scroll view) holding the voice + send controls.
//
//  Voice in = Apple's SYSTEM DICTATION, presented programmatically (see Dictation.swift) so
//  the SAME path serves the on-screen mic and the Action button. Tap the mic (or press the
//  Action button) → system dictation opens listening → speak → text appends to the draft.
//  (SFSpeechRecognizer doesn't work on watchOS, so an in-app always-on listener isn't
//  possible; this is the real, high-quality dictation.)
//
//  Send carries `.handGestureShortcut(.primaryAction)` so the hardware DOUBLE-TAP sends, on
//  Series 9 / Ultra 2+. Only ONE primary action per screen, outside a ScrollView — hence this
//  fixed bar. Tapping the draft opens the crown-cursor editor (CaretEditorView) for mid-message
//  edits. The draft lives in the store so the Action-button dictation can populate it too.
//

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var store: PinchStore
    @State private var showEditor = false
    @State private var showActions = false

    private var connected: Bool {
        if case .ready = store.connection { return true }
        return false
    }

    private var canSend: Bool {
        connected && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool {
        store.agentState == .thinking || store.agentState == .running_tool || store.agentState == .waiting_permission
    }

    var body: some View {
        VStack(spacing: 4) {
            // Draft preview — tap to open the crown-cursor editor.
            if !store.draft.isEmpty {
                Button { showEditor = true } label: {
                    Text(store.draft)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                // Mic → Apple system dictation (same path the Action button uses).
                Button {
                    Dictation.present { store.appendDictated($0) }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 40)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Dictate")

                SendButton(enabled: canSend) { sendNow() }

                // watchOS has no `Menu`, so the overflow is a confirmationDialog (action sheet).
                Button {
                    showActions = true
                } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .frame(width: 30)
                .accessibilityLabel("More actions")
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
        .animation(.snappy, value: store.draft.isEmpty)
        .sheet(isPresented: $showEditor) {
            CaretEditorView(text: $store.draft, onSend: { sendNow() })
        }
        .confirmationDialog("Actions", isPresented: $showActions, titleVisibility: .hidden) {
            if !store.draft.isEmpty {
                Button("Edit message") { showEditor = true }
            }
            if isBusy {
                Button("Cancel turn", role: .destructive) { store.cancel() }
            }
            if !store.draft.isEmpty {
                Button("Clear", role: .destructive) { store.draft = "" }
            }
        }
    }

    private func sendNow() {
        let text = store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(text)
        store.draft = ""
    }
}

// MARK: - Send (double-tap primary action)

private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
        .disabled(!enabled)
        // Hardware double-tap → Send. No-op on unsupported hardware; on-screen tap still works.
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel("Send")
    }
}
