//
//  CaretEditorView.swift
//  Fine-editing a message with the crown as the cursor — the "arrow keys" model.
//
//  Presented as a SHEET (not pushed on a NavigationStack) on purpose: that keeps the
//  custom right-to-left "delete previous word" swipe from fighting watchOS's edge-swipe-
//  to-go-back, and it lets the crown belong unambiguously to the caret here (only one view
//  can hold crown focus per screen — on the main screen the crown scrolls the transcript).
//
//  Controls:
//    • Crown        → move the caret one character at a time (haptic tick per step).
//    • Mic          → Apple system dictation; the spoken text is inserted AT the caret.
//    • Swipe ←      → delete the word before the caret.
//    • Double-tap / Send → send the message.
//

import SwiftUI
import WatchKit

struct CaretEditorView: View {
    @Binding var text: String
    let onSend: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var caret = 0
    @State private var caretValue = 0.0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text("Edit · turn crown to move cursor")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            ScrollView {
                rendered
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)
            .focusable(true)
            .focused($focused)
            .digitalCrownRotation(
                $caretValue, from: 0, through: Double(max(text.count, 0)), by: nil,
                sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
            )
            .onChange(of: caretValue) { _, v in caret = clamp(Int(v.rounded())) }
            // Right-to-left swipe = delete the previous word.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        guard abs(dx) > abs(dy), dx < -40 else { return }
                        deletePreviousWord()
                    }
            )

            HStack(spacing: 8) {
                // Apple system dictation; inserts the result at the caret.
                Button {
                    Dictation.present { insertAtCaret($0) }
                } label: {
                    Image(systemName: "mic.fill")
                        .frame(width: 42, height: 36)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Dictate at cursor")

                Button {
                    onSend(); dismiss()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .handGestureShortcut(.primaryAction)   // double-tap sends from the editor too
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
        .onAppear {
            caret = text.count
            caretValue = Double(caret)
            focused = true
        }
    }

    /// The text with a caret bar drawn at the insertion point.
    private var rendered: Text {
        let c = clamp(caret)
        let idx = text.index(text.startIndex, offsetBy: c)
        let before = String(text[..<idx])
        let after = String(text[idx...])
        return Text(before)
            + Text("|").foregroundColor(.yellow).bold()
            + Text(after)
    }

    private func clamp(_ i: Int) -> Int { min(max(i, 0), text.count) }

    private func insertAtCaret(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        let c = clamp(caret)
        let idx = text.index(text.startIndex, offsetBy: c)
        // Space-pad if we're wedging between existing words.
        let needsLead = c > 0 && text[text.index(before: idx)] != " "
        let chunk = (needsLead ? " " : "") + s
        text.insert(contentsOf: chunk, at: idx)
        caret = c + chunk.count
        caretValue = Double(caret)
        WKInterfaceDevice.current().play(.click)
    }

    private func deletePreviousWord() {
        let c = clamp(caret)
        guard c > 0 else { return }
        let upto = text.index(text.startIndex, offsetBy: c)
        let head = String(text[..<upto])
        // Trailing spaces + the word before them.
        guard let r = head.range(of: #"\s*\S+\s*$"#, options: .regularExpression) else { return }
        let removeCount = head.distance(from: r.lowerBound, to: r.upperBound)
        let start = text.index(text.startIndex, offsetBy: c - removeCount)
        text.removeSubrange(start..<upto)
        caret = c - removeCount
        caretValue = Double(caret)
        WKInterfaceDevice.current().play(.directionDown)
    }
}
