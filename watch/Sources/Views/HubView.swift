//
//  HubView.swift
//  The upper-left hub. Tapping the top-left folder icon lands here on two destinations:
//    • Folder — the project/folder picker. Sets the FOCUSED agent's soft folder hint (cwd stays at
//      the project root; the choice just steers the agent and relabels its row).
//    • Agents — the multi-agent switcher: create, focus, or remove agents (each a separate backend
//      session on the Mac).
//  Splitting "which folder is this agent in" from "which agent am I driving" keeps the tiny screen
//  uncluttered — they're two different questions, and the watch can only show one thing at a time.
//

import SwiftUI

struct HubView: View {
    @EnvironmentObject private var store: PinchStore

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ProjectPickerView()
                } label: {
                    Label("Folder", systemImage: "folder")
                        .font(.system(size: 16, weight: .medium))
                }

                NavigationLink {
                    AgentListView()
                } label: {
                    HStack {
                        Label("Agents", systemImage: "rectangle.stack")
                            .font(.system(size: 16, weight: .medium))
                        Spacer(minLength: 4)
                        // Count of running agents, so the hub hints there's more than one.
                        Text("\(store.agents.count)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Switch")
        }
    }
}
