//
//  CaretEditorView.swift  → now hosts InlineDraftEditor.
//
//  The old separate crown-cursor EDIT SCREEN (a sheet) is gone. Its caret-index + crown +
//  back-swipe-delete logic now lives here as a REUSABLE INLINE VIEW used INSIDE the draft box
//  in ComposerView, bound directly to store.draft. (Filename kept so the Xcode project ref is
//  stable; the public type is InlineDraftEditor.)
//
//  ── INTERACTION MODEL (the crown handoff) ─────────────────────────────────────────────────
//  The draft box has TWO independent toggles, and the Digital Crown has TWO possible owners
//  (the chat transcript, or this input). `store.inputOwnsCrown` is the single source of truth
//  for who holds the crown; TranscriptView yields its scroll focus whenever it's true.
//
//    • Collapsed + crown→chat  (default): box ~1 line. Crown scrolls the CHAT. Orange arrow
//      at the top points UP.
//    • EDIT button             : expands the box, gives it the crown, and the crown MOVES THE
//      CARET (haptic tick per char). A leading back-swipe (←) deletes the previous word.
//    • Orange arrow (UP→DOWN)  : expands the box, gives it the crown in SCROLL mode (crown
//      scrolls the draft text, no caret). Arrow now points DOWN.
//    • Orange arrow (DOWN→UP) / EDIT-again / collapse: returns to one line and hands the crown
//      BACK to the chat.
//
//  The arrow ALWAYS lives at the top of the input. UP = "expand / take crown". DOWN = "collapse
//  / give crown back to chat". Whether the expanded crown moves the caret or scrolls the text
//  is decided by `mode` (.edit vs .scroll), set by which control opened the expansion.
//

import SwiftUI
import WatchKit

/// What the crown does while the input is expanded and owns the crown.
enum InlineEditMode {
    case edit       // crown moves the caret; back-swipe deletes a word
    case scroll     // crown scrolls the (long) draft text
}

/// The inline draft editor that lives INSIDE the draft box. Collapsed it's a plain one-line
/// preview; expanded it owns the crown and shows a caret (edit) or scrolls (scroll).
struct InlineDraftEditor: View {
    @Binding var text: String
    /// Caret position (char offset into `text`), lifted into the store so the MIC button can
    /// insert dictation here. The crown moves this in EDIT mode; dictation jumps it.
    @Binding var caretIndex: Int
    /// True when expanded + owning the crown. Bound to store.inputOwnsCrown so the transcript
    /// knows to yield. The orange arrow + EDIT flip this.
    @Binding var ownsCrown: Bool
    /// edit (caret) vs scroll. Only meaningful while ownsCrown.
    let mode: InlineEditMode

    @State private var caretValue = 0.0
    @State private var scrollValue = 0.0
    @FocusState private var focused: Bool

    private var isEmpty: Bool { text.isEmpty }

    var body: some View {
        Group {
            if ownsCrown {
                expanded
            } else {
                collapsed
            }
        }
        // Grab/drop crown focus whenever ownership flips. Focusing THIS view is what pulls the
        // crown away from the chat ScrollView (only the focused .focusable view owns the crown).
        // When taking the crown we DEFER the focus set one runloop hop: on this state change the
        // Group is still swapping collapsed→expanded, so the `.focused($focused)` target isn't in
        // the tree yet and an immediate set silently no-ops — leaving the chat feed still holding
        // the crown (the Bug-2 "both respond" race). Setting it after the expanded view mounts
        // makes the caret editor the SOLE crown consumer; the feed is also hidden by RootView via
        // inputOwnsCrown, so it can't scroll while editing.
        .onChange(of: ownsCrown) { _, owns in
            if owns {
                caretIndex = clampedCaret(caretIndex)
                caretValue = Double(caretIndex)
                scrollValue = 0
                Task { @MainActor in focused = true }
            } else {
                focused = false
            }
        }
        // Keep the crown value following the caret when dictation moves it from outside.
        .onChange(of: caretIndex) { _, c in
            let v = Double(clampedCaret(c))
            if abs(v - caretValue) > 0.5 { caretValue = v }
        }
        .onAppear { if ownsCrown { focused = true; caretValue = Double(clampedCaret(caretIndex)) } }
    }

    // MARK: Collapsed — inert one-line preview (no dictation on tap; that's the mic button now).
    private var collapsed: some View {
        Text(isEmpty ? "Tap mic to dictate…" : text)
            .font(.system(size: 14))
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isEmpty ? .secondary : .primary)
    }

    // MARK: Expanded — owns the crown. EDIT shows a caret + follows it; SCROLL scrolls the text.
    private var expanded: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Fill the space the composer hands us (whole screen above the buttons).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable(true)
            .focused($focused)
            // Claim the crown the moment this focusable view actually mounts. This is the reliable
            // half of the focus handoff: by the time .onAppear runs the view is in the tree, so the
            // focus set sticks and the crown is exclusively ours (the chat feed is hidden anyway).
            .onAppear { focused = true }
            .modifier(CrownDriver(
                mode: mode,
                caretValue: $caretValue,
                scrollValue: $scrollValue,
                charCount: text.count
            ))
            // EDIT: crown steps the caret. Move the store caret + scroll its line into view.
            .onChange(of: caretValue) { _, v in
                guard mode == .edit else { return }
                let c = clampedCaret(Int(v.rounded()))
                if c != caretIndex { caretIndex = c }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(caretAnchorID, anchor: .center)
                }
            }
            // SCROLL: crown drives a 0…1 position; map it across the text's word-chunk anchors
            // so long text scrolls proportionally (not just top/bottom).
            .onChange(of: scrollValue) { _, v in
                guard mode == .scroll else { return }
                let n = scrollChunks.count
                guard n > 0 else { return }
                let i = min(n - 1, max(0, Int((v * Double(n - 1)).rounded())))
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("chunk-\(i)", anchor: .top)
                }
            }
            // Leading back-swipe (←) = delete the previous word (edit mode only).
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard mode == .edit else { return }
                        let dx = value.translation.width, dy = value.translation.height
                        guard abs(dx) > abs(dy), dx < -40 else { return }
                        deletePreviousWord()
                    }
            )
        }
    }

    /// Stable id for the caret line so ScrollViewReader can keep it visible (edit mode).
    private let caretAnchorID = "caretAnchor"

    /// The draft split into small word-runs for scroll mode, each gets an `id` so the crown can
    /// scroll to any point proportionally. ~6 words per chunk reads as roughly a line on the watch.
    private var scrollChunks: [String] {
        guard !text.isEmpty else { return [] }
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var chunks: [String] = []
        var i = 0
        while i < words.count {
            chunks.append(words[i..<min(i + 6, words.count)].joined(separator: " "))
            i += 6
        }
        return chunks
    }

    /// One stacked line of the draft in EDIT mode. The chunk that contains the caret carries the
    /// caret split (text before/after the marker) and `hasCaret = true` so it gets the scroll
    /// anchor.
    private struct CaretChunk: Identifiable {
        let index: Int
        let text: String
        let hasCaret: Bool
        /// Char offset of the caret WITHIN this chunk (only when hasCaret); used to split the line.
        let caretInChunk: Int
        var id: Int { index }
    }

    /// Fixed-width per line so a character caret offset maps cleanly to a known line. ~28 chars is
    /// about one wrapped line at size 15 on the Ultra; fine-grained enough that the caret line
    /// tracks smoothly as the crown steps it.
    private static let editLineLength = 28

    /// Split the draft into fixed-length lines and tag the one holding the caret. An empty draft
    /// yields a single empty caret-line so the marker still shows.
    private func caretChunks(caretAt c: Int) -> [CaretChunk] {
        let chars = Array(text)
        guard !chars.isEmpty else {
            return [CaretChunk(index: 0, text: "", hasCaret: true, caretInChunk: 0)]
        }
        let len = Self.editLineLength
        var result: [CaretChunk] = []
        var start = 0
        var line = 0
        while start < chars.count {
            let end = min(start + len, chars.count)
            let slice = String(chars[start..<end])
            // The caret belongs to this line when it falls in [start, end); the very last line
            // also owns a caret sitting exactly at text.count (end of text).
            let ownsCaret = (c >= start && c < end) || (end == chars.count && c >= end)
            result.append(CaretChunk(index: line, text: slice,
                                     hasCaret: ownsCaret, caretInChunk: c - start))
            start = end
            line += 1
        }
        return result
    }

    /// Render one edit line, drawing the coral caret marker inline when this line owns it.
    @ViewBuilder
    private func caretLine(_ piece: CaretChunk) -> some View {
        if piece.hasCaret {
            let chars = Array(piece.text)
            let split = min(max(piece.caretInChunk, 0), chars.count)
            let before = String(chars[..<split])
            let after = String(chars[split...])
            Text(before)
                + Text("|").foregroundColor(Color.pinch).bold()
                + Text(after)
        } else {
            Text(piece.text)
        }
    }

    @ViewBuilder
    private var content: some View {
        if mode == .edit {
            // EDIT renders the draft as stacked chunk-lines (same chunking as scroll mode) and
            // draws the caret INSIDE whichever chunk holds it. The anchor id (caretAnchorID) is
            // attached to that one chunk, so `proxy.scrollTo(caretAnchorID, .center)` tracks the
            // caret's actual LINE as the crown walks it — not the top of the field (the old bug:
            // the anchor used to sit at the whole block's top-leading, so it never followed down).
            let c = clampedCaret(caretIndex)
            let pieces = caretChunks(caretAt: c)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(pieces) { piece in
                    caretLine(piece)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(piece.hasCaret ? caretAnchorID : "edit-\(piece.index)")
                }
            }
        } else if isEmpty {
            Text("Nothing to scroll yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Render as chunks so each has a scroll anchor; visually it's still continuous text.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(scrollChunks.enumerated()), id: \.offset) { i, chunk in
                    Text(chunk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("chunk-\(i)")
                }
            }
        }
    }

    private func clampedCaret(_ i: Int) -> Int { min(max(i, 0), text.count) }

    private func deletePreviousWord() {
        let c = clampedCaret(caretIndex)
        guard c > 0 else { return }
        let upto = text.index(text.startIndex, offsetBy: c)
        let head = String(text[..<upto])
        guard let r = head.range(of: #"\s*\S+\s*$"#, options: .regularExpression) else { return }
        let removeCount = head.distance(from: r.lowerBound, to: r.upperBound)
        let start = text.index(text.startIndex, offsetBy: c - removeCount)
        text.removeSubrange(start..<upto)
        caretIndex = c - removeCount
        caretValue = Double(caretIndex)
        WKInterfaceDevice.current().play(.directionDown)
    }
}

/// Picks the right `.digitalCrownRotation` binding for the current mode. In EDIT the crown
/// steps the caret (0…charCount, haptic ticks); in SCROLL it drives a 0…1 scroll value that we
/// map onto the text's top/bottom anchors. Binding the crown to this focused child is what
/// claims crown ownership away from the chat.
private struct CrownDriver: ViewModifier {
    let mode: InlineEditMode
    @Binding var caretValue: Double
    @Binding var scrollValue: Double
    let charCount: Int

    /// Detent size over the 0…1 scroll range so ONE crown notch advances roughly one chunk/line
    /// rather than the whole field. scrollChunks ≈ one per ~6 words ≈ ~30 chars, so the number of
    /// chunks ≈ charCount/30; the step is 1 / (chunks − 1). Clamped so short drafts still move and
    /// the step is never zero/NaN.
    private var scrollStep: Double {
        let approxChunks = max(Double(charCount) / 30.0, 1)
        return 1.0 / max(approxChunks - 1.0, 1.0)
    }

    func body(content: Content) -> some View {
        switch mode {
        case .edit:
            content.digitalCrownRotation(
                $caretValue, from: 0, through: Double(max(charCount, 0)), by: nil,
                sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
            )
        case .scroll:
            // VIEWING the draft: keep the crown step tiny so a small turn nudges the text a line
            // at a time instead of whipping it to the top. `.low` sensitivity + a fine `by:` step
            // (the 0…1 position is divided across `scrollChunks`, so a small step ≈ one chunk/line).
            content.digitalCrownRotation(
                $scrollValue, from: 0, through: 1,
                by: scrollStep, sensitivity: .low,
                isContinuous: false, isHapticFeedbackEnabled: false
            )
        }
    }
}
