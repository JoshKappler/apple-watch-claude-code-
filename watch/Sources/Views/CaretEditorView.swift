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

    // MARK: Collapsed — auto-growing preview. NOT one line: a single line made a long dictation
    // feel "capped" (you could only see the head, the rest read as lost). The box now grows with
    // the text up to `collapsedLineCap` lines so a normal multi-sentence message is fully readable
    // inline; only a genuinely long draft truncates (tail), and the orange UP chevron expands it to
    // the full-screen scroller. The underlying string is never capped — this is purely the viewport.
    private static let collapsedLineCap = 5
    private var collapsed: some View {
        Text(isEmpty ? "Tap mic to dictate…" : text)
            .font(.system(size: 14))
            .lineLimit(1...Self.collapsedLineCap)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isEmpty ? .secondary : .primary)
    }

    // MARK: Expanded — owns the crown. EDIT shows a caret the crown walks; SCROLL is a plain
    // native ScrollView the crown scrolls smoothly (exactly like the main chat transcript).
    @ViewBuilder
    private var expanded: some View {
        if mode == .edit {
            editScroller
        } else {
            scrollViewer
        }
    }

    /// EDIT mode: focusable so the crown drives the caret (a haptic tick per character). A leading
    /// back-swipe (←) deletes the previous word. The caret's line carries the scroll anchor so the
    /// field follows the caret as it walks.
    private var editScroller: some View {
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
            // Claim the crown the moment this focusable view mounts (the chat feed is hidden anyway).
            .onAppear { focused = true }
            .modifier(CrownDriver(caretValue: $caretValue, charCount: text.count))
            .onChange(of: caretValue) { _, v in
                let c = clampedCaret(Int(v.rounded()))
                if c != caretIndex { caretIndex = c }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(caretAnchorID, anchor: .center)
                }
            }
            // Leading back-swipe (←) = delete the previous word — from ANYWHERE in the box.
            // contentShape(Rectangle()) makes the WHOLE editor frame hit-testable: without it a
            // ScrollView only registers touches where its text glyphs are, so a left-swipe only
            // "worked" when it happened to land on the caret's line (the line with text under your
            // finger). simultaneousGesture lets the swipe coexist with the scroll/crown instead of
            // being swallowed by it. The horizontal guard means vertical drags still scroll.
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        guard abs(dx) > abs(dy), dx < -40 else { return }
                        deletePreviousWord()
                    }
            )
        }
    }

    /// SCROLL mode (just VIEWING the draft before sending): a PLAIN ScrollView with NO crown
    /// binding and NO `.focusable`. On watchOS a ScrollView scrolls with the crown by default, and
    /// since the chat transcript is hidden while the input is expanded there's nothing else
    /// competing for the crown — so this scrolls smoothly line-by-line, the SAME way the main chat
    /// body does. (The old version mapped the crown across a handful of word-chunk anchors via
    /// `proxy.scrollTo`, which is why a small turn whipped it top↔bottom instead of scrolling.)
    private var scrollViewer: some View {
        ScrollView(.vertical) {
            Text(isEmpty ? "Nothing to scroll yet." : text)
                .font(.system(size: 15))
                .foregroundStyle(isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Stable id for the caret line so ScrollViewReader can keep it visible (edit mode).
    private let caretAnchorID = "caretAnchor"

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

    /// Target characters per line. Kept small enough that a word-wrapped line fits ONE visual line
    /// at size 15 on the Ultra — so lines never wrap a second time (the wrap-of-a-fixed-slice was
    /// what produced the staggered "full line / 2-word line" look).
    private static let editLineLength = 22

    /// Split the draft into evenly-filled lines and tag the one holding the caret. Greedy word
    /// wrap: each line fills up to `editLineLength`, breaking at the last SPACE so whole words stay
    /// together (a single over-long word hard-breaks). The breaking space is kept at the line's end
    /// so character offsets stay CONTIGUOUS (line.start + line.count == nextLine.start), which makes
    /// the caret→line mapping exact. An empty draft yields one empty caret-line so the marker shows.
    private func caretChunks(caretAt c: Int) -> [CaretChunk] {
        let chars = Array(text)
        guard !chars.isEmpty else {
            return [CaretChunk(index: 0, text: "", hasCaret: true, caretInChunk: 0)]
        }
        let maxLen = Self.editLineLength
        var result: [CaretChunk] = []
        var start = 0
        var line = 0
        while start < chars.count {
            var end: Int
            if chars.count - start <= maxLen {
                end = chars.count
            } else {
                // Look back from the line's far edge for a space to break after; if the line has no
                // space (one long word), hard-break at maxLen.
                var brk = -1
                var j = start + maxLen - 1
                while j > start {
                    if chars[j] == " " { brk = j; break }
                    j -= 1
                }
                end = brk > start ? brk + 1 : start + maxLen
            }
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

    /// EDIT-mode content: the draft rendered as stacked fixed-width lines with the caret drawn
    /// INSIDE whichever line holds it. The anchor id (caretAnchorID) rides that one line, so
    /// `proxy.scrollTo(caretAnchorID, .center)` tracks the caret's actual LINE as the crown walks
    /// it. (SCROLL mode doesn't use this — it's a plain native ScrollView; see scrollViewer.)
    private var content: some View {
        let c = clampedCaret(caretIndex)
        let pieces = caretChunks(caretAt: c)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(pieces) { piece in
                caretLine(piece)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(piece.hasCaret ? caretAnchorID : "edit-\(piece.index)")
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

/// Binds the crown to the caret in EDIT mode: 0…charCount, a haptic tick per character step.
/// Binding the crown to this focused child is what claims crown ownership for caret editing.
/// SCROLL mode no longer uses this — it relies on the ScrollView's built-in native crown scroll.
private struct CrownDriver: ViewModifier {
    @Binding var caretValue: Double
    let charCount: Int

    func body(content: Content) -> some View {
        content.digitalCrownRotation(
            $caretValue, from: 0, through: Double(max(charCount, 0)), by: nil,
            sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
        )
    }
}
