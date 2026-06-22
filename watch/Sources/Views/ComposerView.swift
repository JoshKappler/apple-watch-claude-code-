//
//  ComposerView.swift
//  Fixed bottom bar (NOT inside a scroll view) holding the draft box + input controls.
//
//  Voice in = Apple's SYSTEM DICTATION, presented programmatically (see Dictation.swift). It is
//  triggered ONLY by the MIC button now (the draft box tap no longer dictates). The mic is the
//  primary, coral-tinted input. SFSpeechRecognizer doesn't work on watchOS; this system path is
//  the real, high-quality dictation.
//
//  SEND is the hardware DOUBLE PINCH (`.handGestureShortcut(.primaryAction)`, Series 9 /
//  Ultra 2+). The Send button is ALWAYS visible and stays ENABLED whenever there's a draft and
//  the socket is alive.
//
//  Bottom bar = exactly 3 buttons: [edit] [mic] [send].
//    • EDIT (pencil, left)  → expands the draft box + crown MOVES THE CARET (+ back-swipe deletes
//      a word). Inline — NO sheet. See InlineDraftEditor.
//    • MIC  (mic.fill, mid, coral) → Apple system dictation → store.appendDictated.
//    • SEND (paperplane, right) → send + double-pinch.
//  Mode/permissions moved to Settings (top section). Projects + the connection dot live in the
//  top toolbar (RootView).
//
//  EXPAND / CROWN HANDOFF: a small chevron in an ORANGE CIRCLE sits at the TOP of the draft box.
//  Collapsed it points UP (tap → expand + give the input the crown in SCROLL mode); expanded it
//  points DOWN (tap → collapse + hand the crown back to the chat). EDIT also expands, but in
//  caret mode. `store.inputOwnsCrown` is the shared flag the transcript watches so it yields
//  crown focus. See InlineDraftEditor for the full model.
//

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var store: PinchStore

    /// True while the box is expanded and owns the crown (edit OR scroll).
    private var expanded: Bool { store.inputOwnsCrown }
    /// edit (caret) vs scroll, set by which control opened the expansion.
    @State private var editMode: InlineEditMode = .scroll

    /// True when the draft has nothing to send (trimmed empty).
    private var draftIsEmpty: Bool {
        store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send is live whenever there's something to send AND the socket isn't permanently dead. This
    /// only drives the button's COLOR/fill now — the button stays tappable when empty so the
    /// double-pinch primary action can fall through to the mic (see primaryAction()).
    private var canSend: Bool {
        store.connection.isAlive && !draftIsEmpty
    }

    /// The Send button's tap AND the hardware double-pinch route through here: with text it sends,
    /// empty it opens dictation (same call the mic button uses). So a double-pinch on an empty
    /// draft starts talking; with a draft it ships.
    private func primaryAction() {
        if draftIsEmpty {
            Dictation.present { store.dictateAtCaret($0) }
        } else {
            store.send(store.draft)
        }
    }

    var body: some View {
        Group {
            // Chrome collapsed (via a vertical swipe — see RootView): hide the draft box +
            // edit/mic so the transcript fills the screen. Keep the Send button mounted so the
            // hardware double-pinch still works. Doesn't apply while the input is expanded.
            if store.chromeCollapsed && !expanded {
                collapsedBar
            } else {
                fullComposer
            }
        }
        .animation(.snappy, value: store.chromeCollapsed)
        .animation(.snappy, value: store.draft.isEmpty)
        .animation(.snappy, value: store.inputOwnsCrown)
    }

    private var fullComposer: some View {
        VStack(spacing: 4) {
            draftBox
                .padding(.horizontal, 6)
                // Expanded: the box fills all vertical space above the button row.
                .frame(maxHeight: expanded ? .infinity : nil)

            // Bottom bar: exactly THREE buttons → [edit] [mic] [send].
            HStack(alignment: .bottom, spacing: 6) {
                // EDIT — expand the box + crown moves the caret. Highlighted while in edit mode.
                BarButton(systemName: "pencil",
                          tint: (expanded && editMode == .edit) ? .pinch : .primary,
                          label: "Edit message",
                          corner: .left) {
                    toggleEdit()
                }

                // MIC — the primary input. Coral-tinted. Apple system dictation only here.
                BarButton(systemName: "mic.fill",
                          tint: .pinch,
                          label: "Dictate",
                          corner: .none) {
                    // Expanded/editing → insert at the caret; collapsed → append to end.
                    Dictation.present { store.dictateAtCaret($0) }
                }

                // SEND — always visible, carries the double-pinch primary action. Outer-right.
                // `live` only sets the coral fill; the button stays tappable so an empty-draft
                // pinch/tap opens the mic instead of being a dead control.
                SendButton(live: canSend, corner: .right) { primaryAction() }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, BarButtonGeometry.bottomGap)
        }
        // SWIPE DOWN on the composer (a NON-scrolling surface, so the gesture actually fires —
        // unlike a swipe over the transcript, whose scroll view swallows it) collapses all chrome.
        // Disabled while the input is expanded so the editor's own caret/scroll gestures win.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 14)
                .onEnded { value in
                    let dy = value.translation.height
                    guard abs(dy) > abs(value.translation.width), dy > 14 else { return }
                    store.chromeCollapsed = true
                    Haptics.click()
                },
            including: expanded ? .subviews : .all
        )
    }

    /// Collapsed chrome (via a swipe-down): EVERYTHING is hidden — the draft box, all three
    /// buttons, and (in RootView) the top folder/gear icons — so the transcript fills the WHOLE
    /// screen for reading. The only thing left is a small orange UP chevron at the very bottom:
    /// tap it (or swipe up) to bring the composer + top icons back. It always points UP — up means
    /// "reveal / expand", never down.
    private var collapsedBar: some View {
        Button { store.chromeCollapsed = false } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 22)
                .background(Capsule().fill(Color.orange))
                .frame(maxWidth: .infinity, minHeight: 30)   // taller swipe/tap target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show controls")
        // Swipe UP on this bar (a non-scrolling surface) restores the chrome — the symmetric
        // counterpart to the composer's swipe-down-to-collapse. Tap still works too.
        .gesture(
            DragGesture(minimumDistance: 14)
                .onEnded { value in
                    let dy = value.translation.height
                    guard abs(dy) > abs(value.translation.width), dy < -14 else { return }
                    store.chromeCollapsed = false
                    Haptics.click()
                }
        )
        .padding(.bottom, BarButtonGeometry.bottomGap)
    }

    // MARK: - Draft box (orange expand arrow on top + inline editor inside)

    /// The expand chevron only matters when there's text to view/scroll (or we're already
    /// expanded). When the draft is empty there's nothing to expand, so it's hidden — which also
    /// keeps it out of the way and lets the chat feed run right down to the input bar.
    private var showExpandChevron: Bool { expanded || !draftIsEmpty }

    private var draftBox: some View {
        // Chevron lives INLINE on the right of the text/hint — NOT as a notch on the top border.
        // That keeps the box's top edge clean so nothing overlaps the transcript above it. It
        // flips: UP = collapsed (tap to expand + take the crown), DOWN = expanded (tap to collapse).
        HStack(alignment: .top, spacing: 6) {
            InlineDraftEditor(
                text: $store.draft,
                caretIndex: $store.caretIndex,
                ownsCrown: $store.inputOwnsCrown,
                mode: editMode
            )
            // Expanded: let the editor's ScrollView take all remaining vertical space.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: expanded ? .infinity : nil)

            if showExpandChevron {
                Button { toggleExpand() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse input, return crown to chat" : "Expand input, take crown")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxHeight: expanded ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    private var borderColor: Color {
        if expanded { return Color.pinch }
        return store.draft.isEmpty ? Color.white.opacity(0.15) : Color.pinch.opacity(0.7)
    }

    // MARK: - Toggles

    /// EDIT button: expand into caret mode, or collapse if already editing.
    private func toggleEdit() {
        if expanded && editMode == .edit {
            collapse()
        } else {
            editMode = .edit
            store.inputOwnsCrown = true
        }
    }

    /// Orange arrow: expand into scroll mode, or collapse + return crown to chat.
    private func toggleExpand() {
        if expanded {
            collapse()
        } else {
            editMode = .scroll
            store.inputOwnsCrown = true
        }
    }

    private func collapse() {
        store.inputOwnsCrown = false
        editMode = .scroll
    }
}

// MARK: - Bottom-bar buttons

/// Which side of the row a button is on, so the outer ones can curve with the screen corner.
fileprivate enum BarCorner { case left, right, none }

/// Squat bordered icon button. EVERY button uses the identical frame + zero vertical offset so
/// all three tops AND bottoms line up exactly — the only per-button difference is the background
/// SHAPE (outer buttons curve their outer-bottom corner).
private struct BarButton: View {
    let systemName: String
    let tint: Color
    let label: String
    let corner: BarCorner
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: BarButtonGeometry.minHeight)
                .barButtonBackground(corner: corner, fill: Color.white.opacity(0.14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Send button — its own type so the `.handGestureShortcut(.primaryAction)` stays anchored to
/// a single visible control. Same frame/height as BarButton so tops/bottoms match.
///
/// It is NEVER `.disabled`: a disabled button can't receive the hardware double-pinch, and we want
/// the pinch to open the mic when the draft is empty. `live` (there's sendable text) only controls
/// the coral fill — dimmed when empty so it still reads as "nothing queued to send yet".
private struct SendButton: View {
    let live: Bool
    let corner: BarCorner
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // ALWAYS a paperplane — never a second mic. (There's already a dedicated mic button;
            // showing a mic here too was confusing.) Dimmed when there's nothing to send. An
            // empty-draft pinch still opens dictation via primaryAction(), the icon just stays Send.
            Image(systemName: "paperplane.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: BarButtonGeometry.minHeight)
                .barButtonBackground(corner: corner, fill: Color.pinch.opacity(live ? 1.0 : 0.55))
        }
        .buttonStyle(.plain)
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel(live ? "Send" : "Dictate")
    }
}

// MARK: - Bottom-bar button background (shallow concentric-corner shape)

/// Shared geometry + the TUNABLE constants for the bottom bar.
///
/// APPROACH: a SHALLOW outer-bottom corner. Rounding the outer-bottom with a radius centered
/// *inside* the 32pt-tall button turns the whole corner into a tight quarter-circle — a fat
/// diagonal slice (the old bug). Instead we trace a large-radius arc whose center sits FAR
/// outside the button, down past its outer-bottom tip — geometrically the same idea as being
/// concentric with the watch's big rounded screen corner. Over the button's small span that arc
/// is gentle: it shaves only a thin sliver off the very outer-bottom tip, leaving the button
/// nested just inside the screen corner with a small, roughly uniform gap. All other corners use
/// the small uniform `innerRadius`, so every button TOP stays perfectly level.
///
/// The shape is built purely from the button's own local rect (watchOS `.global` GeometryReader
/// frames are NOT anchored to the physical screen, so a true screen-coordinate solve is
/// unreliable here — this local approximation gives the identical visual with no fragile
/// coordinate math).
enum BarButtonGeometry {
    // -- TUNABLE GEOMETRY (Ultra 3 49mm, ~211×257pt) --------------------------------------
    /// Small radius for top corners + inner-bottom corner. Keeps all tops uniform.
    static let innerRadius: CGFloat = 9
    /// Button height — squat. Every button shares this exact height.
    static let minHeight: CGFloat = 32
    /// Tiny gap below the row so buttons don't physically touch the bottom edge.
    static let bottomGap: CGFloat = 3

    /// Radius of the shallow outer-bottom arc — large, ~matching the watch's rounded SCREEN
    /// corner (Ultra 3 49mm ≈ 40pt) minus a few pt of gap so the button nests just inside it.
    /// LARGER ⇒ shallower curve (thinner sliver removed). This is the "concentric" radius.
    static let outerArcRadius: CGFloat = 28
    /// How far IN from the outer side edge the bottom edge starts curving up (pt). Together with
    /// `outerArcRadius` this fixes the shallow arc. Small ⇒ less material removed. ~12–16 reads well.
    static let cornerCut: CGFloat = 16
    // -------------------------------------------------------------------------------------
}

extension View {
    /// Fills the button background. The middle button gets a plain rounded rect; the two outer
    /// buttons get the shallow concentric outer-bottom corner so they hug the screen's corner.
    @ViewBuilder
    fileprivate func barButtonBackground<F: ShapeStyle>(corner: BarCorner, fill: F) -> some View {
        switch corner {
        case .none:
            background(RoundedRectangle(cornerRadius: BarButtonGeometry.innerRadius).fill(fill))
        case .left, .right:
            background(ConcentricCornerShape(corner: corner).fill(fill))
        }
    }
}

/// Rounded-rect whose OUTER-bottom corner is a SHALLOW large-radius arc (see BarButtonGeometry).
/// All other corners use the small uniform `innerRadius` so every button top is level.
private struct ConcentricCornerShape: Shape {
    let corner: BarCorner                 // .left or .right (outer button side)

    func path(in rect: CGRect) -> Path {
        let inner = BarButtonGeometry.innerRadius
        let isRight = (corner == .right)
        let arcR = max(BarButtonGeometry.outerArcRadius, inner)
        // The two points where the shallow arc meets the button edges.
        let cut = min(BarButtonGeometry.cornerCut, rect.width - inner)

        var p = Path()

        if isRight {
            // outer corner = bottom-RIGHT.
            let pBottom = CGPoint(x: rect.maxX - cut, y: rect.maxY)          // on bottom edge
            let cx = rect.maxX
            let dx = cx - pBottom.x
            let cy = pBottom.y + sqrt(max(arcR * arcR - dx * dx, 0))         // center below bottom edge
            let center = CGPoint(x: cx, y: cy)
            let pRight = CGPoint(x: rect.maxX, y: cy - arcR)
            p.move(to: CGPoint(x: rect.minX + inner, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - inner, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.maxX - inner, y: rect.minY + inner),
                     radius: inner, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: max(pRight.y, rect.minY + inner)))
            let startA = atan2(pRight.y - center.y, pRight.x - center.x)
            let endA   = atan2(pBottom.y - center.y, pBottom.x - center.x)
            p.addArc(center: center, radius: arcR,
                     startAngle: .radians(startA), endAngle: .radians(endA), clockwise: true)
            p.addLine(to: CGPoint(x: rect.minX + inner, y: rect.maxY))
            p.addArc(center: CGPoint(x: rect.minX + inner, y: rect.maxY - inner),
                     radius: inner, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        } else {
            // outer corner = bottom-LEFT.
            let pBottom = CGPoint(x: rect.minX + cut, y: rect.maxY)          // on bottom edge
            let cx = rect.minX
            let dx = pBottom.x - cx
            let cy = pBottom.y + sqrt(max(arcR * arcR - dx * dx, 0))
            let center = CGPoint(x: cx, y: cy)
            let pLeft = CGPoint(x: rect.minX, y: cy - arcR)
            p.move(to: CGPoint(x: rect.minX + inner, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - inner, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.maxX - inner, y: rect.minY + inner),
                     radius: inner, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inner))
            p.addArc(center: CGPoint(x: rect.maxX - inner, y: rect.maxY - inner),
                     radius: inner, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: pBottom)
            let startA = atan2(pBottom.y - center.y, pBottom.x - center.x)
            let endA   = atan2(pLeft.y - center.y, pLeft.x - center.x)
            p.addArc(center: center, radius: arcR,
                     startAngle: .radians(startA), endAngle: .radians(endA), clockwise: true)
            p.addLine(to: CGPoint(x: rect.minX, y: max(pLeft.y, rect.minY + inner)))
        }

        // Outer-top small corner (top-LEFT for both layouts) closes back to the start point.
        p.addArc(center: CGPoint(x: rect.minX + inner, y: rect.minY + inner),
                 radius: inner, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
