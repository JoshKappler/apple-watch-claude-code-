//
//  ProjectPickerView.swift
//  Pick which repo the agent operates in, with the crown: turn to highlight, pause to commit
//  (CrownPicker), or tap a row. Selecting sends `select_project`; the server re-scopes and
//  replies `ready`.
//

import SwiftUI

struct ProjectPickerView: View {
    @EnvironmentObject private var store: PinchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 6) {
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
                .frame(maxHeight: .infinity)
            } else {
                Text("Project · turn crown, pause to pick")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                CrownPicker(
                    items: store.projects,
                    title: { $0.name },
                    subtitle: { project in
                        var parts: [String] = []
                        if let branch = project.branch { parts.append(branch) }
                        if project.dirty == true { parts.append("• dirty") }
                        return parts.joined(separator: "  ")
                    },
                    initialIndex: store.projects.firstIndex(where: { $0.id == store.currentProject?.id }) ?? 0,
                    onCommit: { project in
                        store.selectProject(project)
                        dismiss()
                    }
                )
            }
        }
        .onAppear { store.listProjects() }
    }
}
