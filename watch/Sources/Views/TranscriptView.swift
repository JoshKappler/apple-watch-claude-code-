//
//  TranscriptView.swift
//  Scrollable conversation: user prompts, assistant text (with a speaking pulse),
//  tool chips, and a subtle thinking indicator.
//
//  SCROLLING IS CROWN-ONLY — the FINGER never scrolls the chat. The ScrollView is
//  `.scrollDisabled(true)` and we drive it from the Digital Crown ourselves (a
//  `.digitalCrownRotation` binding → the watchOS-11 `ScrollPosition` API). Why: the finger is
//  reserved for the VERTICAL SWIPE that collapses/expands the bottom chrome (see the gesture
//  below), and a touch-scrolling ScrollView's UIKit pan recognizer would otherwise swallow that
//  swipe (~half the time — the bug behind several failed attempts). Disabling touch scroll frees
//  the finger for the swipe; the crown keeps scrolling.
//
//  FOLLOW-THE-BOTTOM: by default the feed tracks the newest content so the latest activity stays
//  in view. Crowning UP away from the floor BREAKS AWAY (read backscroll while the agent keeps
//  working — nothing yanks you down); crowning back to the floor RE-ENGAGES following. Decided
//  from the crown offset + live scroll geometry, never from screen swipes.
//

import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject private var store: PinchStore

    /// Whether the feed is currently tracking the bottom. Starts true; crowning up past the floor
    /// turns it off, reaching the floor turns it back on. Auto-scroll is gated on this.
    @State private var following = true

    /// How close to the content's bottom (in points) still counts as "at the floor" — a forgiving
    /// band so you don't have to land on the exact last pixel to re-engage following.
    private let bottomBand: CGFloat = 24

    // ── CROWN-ONLY SCROLL (no finger scroll) ────────────────────────────────────────────────
    // The ScrollView is `.scrollDisabled(true)`, so the FINGER never scrolls — the crown does it,
    // through these. We OWN crown focus explicitly (focusable + .focused): the old version relied
    // on being the IMPLICIT default crown target, so after the composer or system dictation took
    // crown focus and dropped it, nothing reclaimed it and the crown went DEAD until you tapped
    // (the "scrolling froze" bug). Now we re-assert focus on appear and the moment the composer
    // hands the crown back. Scrolling itself is programmatic via watchOS-11 `ScrollPosition`:
    // `.scrollDisabled` blocks USER scrolling but `scrollTo` still moves the view.
    @FocusState private var crownFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// Crown-driven absolute scroll offset, in points from the top. Bound to the Digital Crown.
    @State private var crownY: Double = 0
    /// Measured directly with `.onGeometryChange` (NOT `.onScrollGeometryChange`, which can go
    /// quiet under `.scrollDisabled`). Plain geometry always fires, so `maxScroll` is reliable —
    /// without it the crown's upper bound would be 0 and the crown couldn't scroll at all.
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// Max scrollable offset = content − viewport (clamped ≥ 0). The crown's upper bound.
    private var maxScroll: CGFloat { max(contentHeight - viewportHeight, 0) }

    /// The agent is actively working — drives the rich thinking indicator (client-side).
    private var isWorking: Bool {
        store.agentState == .thinking || store.agentState == .running_tool
    }

    var body: some View {
        ScrollView {
            // NON-lazy VStack: a LazyVStack does not measure off-screen rows, so the content's
            // true end (and thus `scrollTo(edge: .bottom)`) would be a moving target as rows lay
            // out lazily. A plain VStack measures every row up front. Watch transcripts are short;
            // eager layout is cheap and worth the correctness.
            VStack(alignment: .leading, spacing: 8) {
                // Persistent connection status — first row, stays visible even with messages.
                ConnectionPill(state: store.connection,
                               agent: store.agentState,
                               reconnect: { store.reconnect() })
                if store.transcript.isEmpty {
                    EmptyHint()
                }
                ForEach(store.transcript) { item in
                    row(for: item).id(item.id)
                }
                if isWorking {
                    ThinkingIndicator(agent: store.agentState, startedAt: store.turnStartedAt)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 6)
            // Content height — the scrollable extent. Plain geometry, so it reports even though the
            // ScrollView is scrollDisabled.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                contentHeight = h
                pinToFloorIfFollowing()
            }
        }
        // Viewport height — the ScrollView's own frame.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            viewportHeight = h
            pinToFloorIfFollowing()
        }
        // Programmatic scroll target (watchOS 11). Moved by the crown handler + follow logic only.
        .scrollPosition($scrollPosition)
        // The finger CANNOT scroll the chat — that's what makes the collapse/expand swipe (below)
        // reliable, and is the intended interaction. The crown scrolls instead (see below).
        .scrollDisabled(true)
        // Own the crown explicitly so it never goes dead after the composer borrows it.
        .focusable(true)
        .focused($crownFocused)
        // SMOOTH + NATIVE-PACED + SILENT. Continuous (`by: nil`) so there are no detents — the chat
        // glides like the built-in watchOS ScrollView instead of clicking in chunks — and
        // `isHapticFeedbackEnabled: false` keeps the crown silent (no tick). `.high` sensitivity sets
        // the pace: `.medium` here scrolled far too slowly, so `.high` continuous is tuned to match
        // the native crown's steady-turn speed. (The OS scroll also has spin-to-fling momentum a
        // position-based binding can't reproduce; this matches the steady pace, not the fling.)
        .digitalCrownRotation($crownY, from: 0, through: Double(max(maxScroll, 1)),
                              by: nil, sensitivity: .high, isContinuous: false,
                              isHapticFeedbackEnabled: false)
        // Crown turned: scroll to the new offset. Landing within the bottom band re-engages
        // following (and snaps exactly to the floor); anywhere above breaks away so you can read
        // backscroll while the agent keeps working.
        .onChange(of: crownY) { _, y in
            let atBottom = y >= Double(maxScroll) - bottomBand
            following = atBottom
            if atBottom { scrollPosition.scrollTo(edge: .bottom) }
            else { scrollPosition.scrollTo(y: y) }
        }
        // New items. A locally-sent USER prompt is an explicit "take me to the bottom" — re-engage
        // following even if we'd crowned up to read. Agent-driven growth respects the follow state.
        .onChange(of: store.transcript.count) { old, new in
            // Reclaim the crown on every new bubble. This is the exact moment the crown used to go
            // dead (send → reply), e.g. after the system dictation sheet dismissed without handing
            // focus back. Harmless when we already hold it. Safe to force here: while the composer
            // is expanded (it owns the crown) this view isn't mounted, so it can't steal focus.
            crownFocused = true
            if new > old, let last = store.transcript.last, case .user = last {
                following = true
            }
            if following {
                crownY = Double(maxScroll)
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: isWorking) { _, active in
            if active && following { scrollPosition.scrollTo(edge: .bottom) }
        }
        // Reclaim the crown the instant the composer hands it back (collapse from expanded/edit).
        // The transcript also re-mounts in that case, but this covers the in-place handoff too.
        .onChange(of: store.inputOwnsCrown) { _, owns in
            if !owns { crownFocused = true }
        }
        // ── Collapse / expand the bottom chrome with a VERTICAL FINGER SWIPE ──────────────────
        // Reliable ONLY because the ScrollView is scrollDisabled — no scroll pan competes for the
        // drag (the reason every previous over-the-transcript swipe attempt failed). Swipe DOWN
        // hides the composer (chat fills the screen); swipe UP brings it back. The horizontal guard
        // keeps it clear of the system back-swipe; minimumDistance avoids firing on taps so the
        // reconnect pill etc. stay tappable.
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    let dy = value.translation.height, dx = value.translation.width
                    guard abs(dy) > abs(dx), abs(dy) > 18 else { return }
                    let collapse = dy > 0
                    if store.chromeCollapsed != collapse {
                        store.chromeCollapsed = collapse
                        Haptics.click()
                    }
                }
        )
        // Snap to the tail on (re)mount and take the crown. Sending from the EXPANDED composer
        // collapses the input (inputOwnsCrown → false), which RE-INSERTS this view with the just-
        // sent bubble already present, so we must re-pin here. Deferred one runloop so the (non-
        // lazy) content is laid out before we target the bottom edge.
        .onAppear {
            following = true
            crownFocused = true
            DispatchQueue.main.async { scrollPosition.scrollTo(edge: .bottom) }
        }
    }

    /// When the content or viewport grows while following (a streamed delta, a new tool chip, the
    /// thinking indicator), keep the crown pinned to the floor and scroll to the bottom. While
    /// broken away (the user crowned up to read), this no-ops so the feed never fights them.
    private func pinToFloorIfFollowing() {
        guard following else { return }
        crownY = Double(maxScroll)
        scrollPosition.scrollTo(edge: .bottom)
    }

    @ViewBuilder
    private func row(for item: TranscriptItem) -> some View {
        switch item {
        case let .user(_, text, delivery):
            UserBubble(text: text, delivery: delivery)
        case let .assistant(_, text):
            AssistantBubble(text: text, speaking: store.speaker.isSpeaking && isLast(item))
        case let .tool(use, ok):
            ToolChip(use: use, ok: ok)
        case let .notice(_, text, warn):
            NoticeRow(text: text, warn: warn)
        }
    }

    private func isLast(_ item: TranscriptItem) -> Bool {
        store.transcript.last?.id == item.id
    }
}

// MARK: - Rows

// Both bubbles fill the FULL screen width — no side indentation, no avatar/logo. The screen is
// tiny; every pixel of width counts. You tell who's speaking by COLOR alone: coral = you, gray =
// Claude. (The old left spacer on user bubbles and the sparkle on assistant bubbles both stole
// horizontal space and have been removed.)
private struct UserBubble: View {
    let text: String
    var delivery: TranscriptItem.Delivery = .sent
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
            // A user prompt is never silently lost: show "Sending…" until the backend confirms
            // delivery (2xx), or "Not sent" if it terminally failed. Nothing once sent.
            if delivery != .sent {
                HStack(spacing: 3) {
                    Image(systemName: delivery == .sending ? "arrow.up.circle" : "exclamationmark.triangle.fill")
                    Text(delivery == .sending ? "Sending…" : "Not sent")
                }
                .font(.system(size: 9))
                .foregroundStyle(delivery == .sending ? Color.white.opacity(0.7) : Color.yellow)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.pinch.opacity(0.9), in: .rect(cornerRadius: 12))
        .foregroundStyle(.white)
    }
}

private struct AssistantBubble: View {
    let text: String
    let speaking: Bool   // retained for call-site compatibility; no longer drawn (no avatar to pulse)

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.gray.opacity(0.22), in: .rect(cornerRadius: 12))
    }
}

private struct ToolChip: View {
    let use: ServerMsg.ToolUse
    let ok: Bool?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(use.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let subtitle = use.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.gray.opacity(0.14), in: .rect(cornerRadius: 10))
    }

    private var statusSymbol: String {
        switch ok {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "xmark.octagon.fill"
        case .none: return "wrench.and.screwdriver"
        }
    }
    private var statusColor: Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }
}

private struct NoticeRow: View {
    let text: String
    let warn: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(warn ? .orange : .secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Rich Claude-Code-style "working" indicator: a pulsing sparkle mark, a rotating status word
/// that changes every ~2.5s, and a live elapsed timer. Driven entirely client-side from
/// agentState + turnStartedAt (the backend only sends a single `thinking` status, not a stream).
private struct ThinkingIndicator: View {
    let agent: AgentState
    let startedAt: Date?

    /// Claude-Code-flavored status words; we index by elapsed seconds so it rotates steadily.
    private static let words = [
        "Pondering", "Germinating", "Pontificating", "Ruminating", "Percolating",
        "Cogitating", "Marinating", "Noodling", "Conjuring", "Synthesizing",
        "Untangling", "Deliberating", "Brewing", "Mulling", "Tinkering",
        "Calibrating", "Wrangling", "Spelunking", "Schlepping", "Vibing",
    ]
    private static let wordInterval: TimeInterval = 2.5

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            // Animated Claude-style mark — gentle continuous pulse + rotation.
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.pinch)
                .scaleEffect(pulse ? 1.15 : 0.85)
                .rotationEffect(.degrees(pulse ? 25 : -25))
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }

            // Rotating status word — recomputed every wordInterval seconds.
            TimelineView(.periodic(from: .now, by: Self.wordInterval)) { _ in
                Text(statusWord)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            // Live elapsed timer (e.g. "8s", "1m 4s"), recomputed once a second.
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { _ in
                    Text(elapsedText(since: startedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// "Running…" while a tool runs (tools render their own chips); otherwise a rotating word.
    private var statusWord: String {
        if agent == .running_tool { return "Running…" }
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let idx = Int(max(0, elapsed) / Self.wordInterval) % Self.words.count
        return Self.words[idx] + "…"
    }

    private func elapsedText(since start: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(start)))
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }
}

/// Thin, always-legible connection status line pinned to the top of the transcript.
/// Hidden entirely when `.ready`; tappable when it makes sense to retry.
private struct ConnectionPill: View {
    let state: ConnectionState
    let agent: AgentState
    let reconnect: () -> Void

    var body: some View {
        if case .ready = state {
            EmptyView()
        } else {
            let info = info(for: state)
            Group {
                if info.tappable {
                    Button(action: reconnect) { content(info) }
                        .buttonStyle(.plain)
                } else {
                    content(info)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func content(_ info: (text: String, tappable: Bool)) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ConnectionBadge.color(state: state, agent: agent))
                .frame(width: 6, height: 6)
            Text(info.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 8))
    }

    private func info(for state: ConnectionState) -> (text: String, tappable: Bool) {
        switch state {
        case .connecting: return ("Connecting…", false)
        case .connected: return ("Authenticating…", false)
        case .reconnecting(let n): return ("Reconnecting… (\(n))", false)
        case .failed(let msg): return (msg, true)
        case .disconnected: return ("Offline — tap to reconnect", true)
        case .ready: return ("", false)
        }
    }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No messages yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}
