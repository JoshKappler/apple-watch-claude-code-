//
//  ComposerView.swift
//  Fixed bottom bar (NOT inside a scroll view) holding the voice + send + navigation controls.
//
//  Voice in = Apple's SYSTEM DICTATION, presented programmatically (see Dictation.swift) so
//  the SAME path serves the on-screen mic and the Action button. Tap the mic (or press the
//  Action button) → system dictation opens listening → speak → text appends to the draft.
//  (SFSpeechRecognizer doesn't work on watchOS, so an in-app always-on listener isn't
//  possible; this is the real, high-quality dictation.)
//
//  SEND is the hardware DOUBLE PINCH by default (`.handGestureShortcut(.primaryAction)`,
//  Series 9 / Ultra 2+). The on-screen Send button is OFF by default and toggled on in
//  Settings ("Show on-screen Send") — useful in the Simulator, where double pinch doesn't
//  fire, and on older watches. Even when the visible Send button is hidden, a zero-size
//  carrier keeps the double-pinch primary action wired. Only ONE primary action per screen.
//
//  Projects + Mode live here (not the top bar) because watchOS renders only one trailing
//  toolbar item. Tapping the draft opens the crown-cursor editor (CaretEditorView).
//

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var store: PinchStore
    @State private var showEditor = false
    @State private var showActions = false
    @State private var showModes = false
    @State private var showProjects = false

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
            // Draft input box — a clear "chat box" holding the dictated/typed message, ready
            // to send. Always visible (persistent CLI-style prompt) so dictated text never
            // looks "lost". Tap to open the crown-cursor editor.
            Button { showEditor = true } label: {
                Text(store.draft.isEmpty ? "Tap mic to dictate…" : store.draft)
                    .font(.system(size: 14))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(store.draft.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.10)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(store.draft.isEmpty ? Color.white.opacity(0.15) : Color.pinch.opacity(0.7), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)

            HStack(spacing: 6) {
                // Mic → Apple system dictation (same path the Action button uses).
                iconButton("mic.fill", tint: Color.pinch, label: "Dictate") {
                    Dictation.present { store.appendDictated($0) }
                }

                // Send is ALWAYS visible: watchOS Double Tap (double pinch) only binds to a
                // VISIBLE, enabled primary-action button. A hidden 0×0 carrier isn't eligible —
                // that's what triggered the "no primary action" error. This is the one target.
                SendButton(enabled: canSend) { sendNow() }

                // Mode (default / acceptEdits / plan / bypass). Red when bypass is armed.
                iconButton(store.mode.symbol,
                           tint: store.mode == .bypassPermissions ? .red : .primary,
                           label: "Mode") {
                    showModes = true
                }

                // Project picker.
                iconButton("folder", tint: .primary, label: "Projects") {
                    store.listProjects()
                    showProjects = true
                }

                // Overflow — watchOS has no `Menu`, so it's a confirmationDialog.
                iconButton("ellipsis", tint: .primary, label: "More actions") {
                    showActions = true
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 2)
        .animation(.snappy, value: store.draft.isEmpty)
        .sheet(isPresented: $showEditor) {
            CaretEditorView(text: $store.draft, onSend: { sendNow() })
        }
        .sheet(isPresented: $showModes) { ModeMenuView() }
        .sheet(isPresented: $showProjects) { ProjectPickerView() }
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

    /// A compact, equal-width bordered icon button for the bottom bar.
    private func iconButton(_ systemName: String,
                            tint: Color,
                            label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    private func sendNow() {
        let text = store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(text)
        store.draft = ""
    }
}

// MARK: - Send (double-pinch primary action; shown only when enabled in Settings)

private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(.pinch)
        .disabled(!enabled)
        // Hardware double pinch → Send. No-op on unsupported hardware; on-screen tap still works.
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel("Send")
    }
}
