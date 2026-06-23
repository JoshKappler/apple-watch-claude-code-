//
//  PermissionCardView.swift
//  The approve/decline gate. Docks as a NON-blocking bottom BAR when the agent is waiting on you —
//  the transcript stays visible and crown-scrollable above it (see RootView.ConversationScreen).
//  Title is risk-colored; the diff (edits) or command (bash) renders in a finger-scrollable,
//  height-capped monospace area so the bar never starves the chat above.
//
//  THE DECISION IS TAP-ONLY. It used to be crown-driven (a CrownConfirm dial), but a request can
//  appear WHILE you're crown-scrolling the chat — and binding crown rotation to allow/deny meant
//  the in-flight turn could approve or deny by ACCIDENT. Now the crown only scrolls the diff/
//  command above; you decide with the explicit Allow / Deny buttons. High-risk hides the
//  "remember" toggle and tints Allow orange so nothing dangerous reads as routine.
//

import SwiftUI

struct PermissionCardView: View {
    let request: ServerMsg.PermissionRequest
    @EnvironmentObject private var store: PinchStore
    @State private var remember = false

    var body: some View {
        VStack(spacing: 6) {
            header

            // Diff / command / detail — finger-scrollable, HEIGHT-CAPPED so the bar stays a bottom
            // dock and never starves the transcript above it. The crown is NOT bound here; it scrolls
            // the chat. Only shown when there's something to inspect.
            if hasDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        detailContent
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                // DEFINITE height (not just maxHeight): next to the greedy maxHeight:.infinity
                // transcript above, a ScrollView with only a max collapses to zero on watchOS.
                // Size it to the content, capped, so short commands stay compact and long diffs
                // get a finger-scrollable window without starving the chat.
                .frame(height: detailHeight)
            }

            if request.risk != .high {
                Toggle(isOn: $remember) {
                    Text("Remember this session").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 8)
                .sensoryFeedback(.selection, trigger: remember)
            }

            // Plain tap decision — the ONLY way to decide. The crown is no longer bound here, so a
            // request that appears while you're crown-scrolling the chat can't approve/deny itself.
            decisionButtons
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        // A docked bottom bar (NOT a full-screen takeover): the transcript stays visible and
        // crown-scrollable above it. Risk-tinted top border so it reads as an elevated panel.
        // The haptic on appear is fired by the store (handle(.permissionRequest)), not here, so it
        // doesn't double up.
        .background(barBackground)
    }

    /// True when there's a diff/command/detail worth showing in the scrollable area.
    private var hasDetail: Bool {
        request.detail != nil || request.command != nil || request.diff != nil
    }

    /// Content-sized height for the detail scroller, capped so the bar never dominates the screen.
    /// Code (diff/command) is measured by line count; prose detail by a rough wrap estimate.
    private var detailHeight: CGFloat {
        let cap: CGFloat = 64
        if let code = request.diff ?? request.command {
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false).count
            return min(CGFloat(lines) * 15 + 14, cap)
        }
        if let detail = request.detail {
            let lines = max(1, detail.count / 26)   // ~26 chars/line at size 12 on the Ultra
            return min(CGFloat(lines) * 15 + 14, cap)
        }
        return 0
    }

    @ViewBuilder
    private var detailContent: some View {
        if let detail = request.detail, request.diff == nil, request.command == nil {
            Text(detail)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let command = request.command {
            CodeBlock(text: command, isDiff: false)
        }
        if let diff = request.diff {
            CodeBlock(text: diff, isDiff: true)
        }
    }

    /// Elevated docked-panel background: rounded only on the TOP corners (it meets the screen's
    /// bottom edge), filled dark, with a thin risk-colored top border. Extends past the bottom safe
    /// area so the fill reaches the physical edge while the button content stays clear of the curve.
    private var barBackground: some View {
        UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
            .fill(Color(white: 0.11))
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
                    .strokeBorder(riskColor.opacity(0.55), lineWidth: 1)
            )
            .ignoresSafeArea(.container, edges: .bottom)
    }

    private var header: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: kindSymbol)
                Text(request.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(riskColor)
            Text("\(request.tool) · \(request.risk.rawValue) risk")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// The allow/deny decision — explicit taps, the only way to decide. Deny is red, Allow is green
    /// (orange for high-risk). No crown binding, so nothing decides by accident.
    private var decisionButtons: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                store.decline()
            } label: {
                Label("Deny", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button {
                store.approve(remember: remember)
            } label: {
                Label("Allow", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.borderedProminent)
            .tint(request.risk == .high ? .orange : .green)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 6)
        // Clear the rounded screen-bottom curve (the bar background extends into the safe area).
        .padding(.bottom, 10)
    }

    private var riskColor: Color {
        switch request.risk {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }

    private var kindSymbol: String {
        switch request.kind {
        case .command: return "terminal"
        case .edit: return "pencil"
        case .write: return "doc.badge.plus"
        case .other: return "questionmark.circle"
        }
    }
}

/// Monospace code/diff pane with simple per-line diff coloring.
private struct CodeBlock: View {
    let text: String
    let isDiff: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color(for: String(line)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 8))
    }

    private func color(for line: String) -> Color {
        guard isDiff else { return .primary }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .cyan }
        return .primary
    }
}
