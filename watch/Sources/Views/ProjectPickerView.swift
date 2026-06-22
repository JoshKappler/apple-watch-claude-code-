//
//  ProjectPickerView.swift
//  Pick which repo the agent operates in. A plain scrollable LIST: every repository is on
//  screen at once (crown scrolls if they overflow), each row shows the repo name + branch with
//  a small Open button on the far right. No crown-highlight / confirm dance — this is a dev tool;
//  tap a row (or its Open button) to switch. Selecting sends `select_project`; the server
//  re-scopes and replies `ready`.
//

import SwiftUI

struct ProjectPickerView: View {
    @EnvironmentObject private var store: PinchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Project")
        }
        .onAppear { store.listProjects() }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if store.projects.isEmpty {
                VStack(spacing: 6) {
                    if store.projectsLoading {
                        ProgressView()
                        Text("Loading projects…")
                    } else {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 22))
                        Text("No projects configured")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.projects) { project in
                        ProjectRow(
                            project: project,
                            isCurrent: project.id == store.currentProject?.id,
                            open: { open(project) }
                        )
                    }
                }
            }
        }
    }

    private func open(_ project: ProjectRef) {
        store.selectProject(project)
        dismiss()
    }
}

/// One repository row: name + branch/dirty on the left, a small coral Open button on the right.
/// The whole row is also tappable to open (the small button is the explicit affordance).
private struct ProjectRow: View {
    let project: ProjectRef
    let isCurrent: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.pinch)
                    }
                    Text(project.name)
                        .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                }
                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // Small explicit Open button on the far right.
            Button(action: open) {
                Image(systemName: "arrow.forward.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.pinch)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(project.name)")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)   // tapping the row opens it too
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let branch = project.branch { parts.append(branch) }
        if project.dirty == true { parts.append("• dirty") }
        return parts.joined(separator: "  ")
    }
}
