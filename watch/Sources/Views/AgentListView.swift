//
//  AgentListView.swift
//  The agent switcher. Every row is a running agent — its own Claude session on the Mac, all
//  spawned at the project root. Tap one to FOCUS it (your prompts now drive that agent and its
//  conversation comes back on screen). "New agent" spawns a fresh one; swipe a row (or use the
//  trash) to remove one, which ends its backend session. The focused agent keeps a coral check.
//  You can't remove the last agent — there's always exactly one in focus.
//

import SwiftUI

struct AgentListView: View {
    @EnvironmentObject private var store: PinchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(store.agents) { agent in
                AgentRow(
                    agent: agent,
                    isFocused: agent.id == store.focusedAgentId,
                    focus: {
                        store.focusAgent(agent.id)
                        dismiss()
                    }
                )
                .swipeActions(edge: .trailing) {
                    // Guard the last agent — removing it would leave nothing to drive.
                    if store.agents.count > 1 {
                        Button(role: .destructive) {
                            store.removeAgent(agent.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }

            // Add a fresh agent and drop straight onto its clean screen.
            Button {
                store.createAgent()
                dismiss()
            } label: {
                Label("New agent", systemImage: "plus.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.pinch)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Agents")
    }
}

/// One agent row: a coral check when focused, then the agent's label (the folder/root it's scoped
/// to). The whole row is tappable to focus.
private struct AgentRow: View {
    let agent: AgentSlot
    let isFocused: Bool
    let focus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isFocused {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.pinch)
            }
            Text(agent.label)
                .font(.system(size: 15, weight: isFocused ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
        .accessibilityLabel(isFocused ? "\(agent.label), focused" : agent.label)
    }
}
