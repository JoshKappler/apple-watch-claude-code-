//
//  TranscriptView.swift
//  Scrollable conversation: user prompts, assistant text (with a speaking pulse),
//  tool chips, and a subtle thinking indicator. Digital Crown scrolls it (ScrollView
//  is crown-scrollable by default on watchOS); we auto-scroll to the newest item.
//

import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject private var store: PinchStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.transcript.isEmpty {
                        EmptyHint()
                    }
                    ForEach(store.transcript) { item in
                        row(for: item).id(item.id)
                    }
                    if store.thinkingActive {
                        ThinkingIndicator().id("thinking")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
            .onChange(of: store.transcript.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.thinkingActive) { _, active in
                if active { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = store.transcript.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
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

private struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 24)
            Text(text)
                .font(.system(size: 14))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.pinch.opacity(0.9), in: .rect(cornerRadius: 12))
                .foregroundStyle(.white)
        }
    }
}

private struct AssistantBubble: View {
    let text: String
    let speaking: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ZStack {
                Image(systemName: "sparkle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if speaking {
                    Circle()
                        .stroke(Color.blue.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                        .scaleEffect(speaking ? 1.25 : 0.8)
                        .opacity(speaking ? 0 : 1)
                        .animation(.easeOut(duration: 0.9).repeatForever(autoreverses: false), value: speaking)
                }
            }
            .frame(width: 16)
            Text(text)
                .font(.system(size: 14))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.gray.opacity(0.22), in: .rect(cornerRadius: 12))
            Spacer(minLength: 0)
        }
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

private struct ThinkingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.6)))
            }
            Text("thinking")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
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
