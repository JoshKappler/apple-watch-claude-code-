//
//  TranscriptView.swift
//  Scrollable conversation: user prompts, assistant text (with a speaking pulse),
//  tool chips, and a subtle thinking indicator. Digital Crown scrolls it (ScrollView
//  is crown-scrollable by default on watchOS); we auto-scroll to the newest item.
//

import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject private var store: PinchStore

    /// The agent is actively working — drives the rich thinking indicator (client-side).
    private var isWorking: Bool {
        store.agentState == .thinking || store.agentState == .running_tool
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // NON-lazy VStack: a LazyVStack does not measure off-screen rows, so a
                // programmatic scrollTo("BOTTOM") has to GUESS the height of rows below the
                // viewport. When the guess runs tall, the scroll lands past the real content —
                // a full screen of emptiness you have to crank back up from (the "sometimes
                // scrolls into the void" bug). A plain VStack measures every row, so the bottom
                // anchor resolves to the true content end. Watch transcripts are short; eager
                // layout is cheap here and worth the correctness.
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
                            .id("thinking")
                    }
                    // Zero-height tail anchor. Auto-scroll targets THIS (anchor: .bottom) instead of
                    // the last bubble's id: a short last item (a one-line notice/tool chip) scrolled
                    // with anchor:.bottom can leave the content's true end above the viewport floor,
                    // which reads as scrollable emptiness. Anchoring to a fixed tail at the very end
                    // pins the real bottom of the content to the viewport bottom every time.
                    Color.clear.frame(height: 0).id("BOTTOM")
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
            // Stop the crown from flinging past the last message into a screenful of empty space:
            // with .basedOnSize the ScrollView only bounces/overscrolls when the content is actually
            // taller than the viewport, and never past the content's end. (watchOS 9.4+.) This does
            // NOT touch focus or gestures, so the crown still scrolls and the swipe-catcher still
            // collapses chrome.
            .scrollBounceBehavior(.basedOnSize)
            // No .focusable / .focused here. On watchOS a ScrollView scrolls with the crown BY
            // DEFAULT whenever nothing else holds crown focus. The expanded input is the ONLY
            // view that takes focus (and the crown); when it isn't focused, the crown falls back
            // to this ScrollView's default scroll. Making the chat focusable/gated KILLS scrolling.
            .onChange(of: store.transcript.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isWorking) { _, active in
                if active { withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) } }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !store.transcript.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
        }
    }

    @ViewBuilder
    private func row(for item: TranscriptItem) -> some View {
        switch item {
        case let .user(_, text):
            UserBubble(text: text)
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
    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
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
