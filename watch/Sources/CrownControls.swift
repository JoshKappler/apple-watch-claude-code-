//
//  CrownControls.swift
//  The crown IS the select button. watchOS gives apps no Digital Crown *press* event
//  (the press is hard-reserved by the system for Home/Siri/Apple Pay — confirmed against
//  Apple's HIG), so every "confirm/select" here is driven by crown ROTATION instead, and
//  the app never has to leave the screen.
//
//  CrownPicker — pick one of N — built on the plain `.digitalCrownRotation` binding overload
//  (the most broadly available one) + `.onChange`, so there's no dependency on the newer
//  detent/onIdle closure overloads. Rotation snaps a highlight through the rows (a haptic tick
//  per row); stop on one and confirm via the button (or double-pinch). Tapping a row highlights it.
//  Used for the mode and project menus.
//
//  NOTE: the permission gate USED to use a crown-driven CrownConfirm dial. It was removed because a
//  request could appear while you were crown-scrolling the chat and the crown would approve/deny by
//  accident — the gate is plain Allow/Deny buttons now. See PermissionCardView.
//
//  A crown-driven view must be `.focusable()` and hold focus to receive rotation, so each
//  grabs focus on appear (only one crown-focused view per screen).
//

import SwiftUI
import WatchKit

// MARK: - List picker (detent highlight + dwell-to-commit)

struct CrownPicker<Item: Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    var subtitle: ((Item) -> String?)? = nil
    /// Index pre-selected when the picker appears (e.g. the current project).
    var initialIndex: Int = 0
    /// Verb shown on the confirm bar before the highlighted item's name (e.g. "Open").
    var confirmVerb: String = "Select"
    let onCommit: (Item) -> Void

    @State private var value = 0.0
    @State private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            // The crown HIGHLIGHTS rows and SCROLLS the highlight into view (same model as the
            // edit-mode caret) — so the selection is always visible even when the list overflows.
            // It no longer auto-commits; you confirm explicitly below.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == index)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { select(i) }   // tap a row to highlight it
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)   // take the space above the confirm bar
                .focusable(true)
                .focused($focused)
                .digitalCrownRotation(
                    $value, from: 0, through: Double(max(items.count - 1, 0)), by: nil,
                    sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: false
                )
                .onChange(of: value) { _, v in
                    let clamped = min(max(Int(v.rounded()), 0), max(items.count - 1, 0))
                    if clamped != index {
                        index = clamped
                        WKInterfaceDevice.current().play(.click)   // per-row tick
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
                .onChange(of: index) { _, i in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) }
                }
                .onAppear {
                    index = min(max(initialIndex, 0), max(items.count - 1, 0))
                    value = Double(index)
                    focused = true
                    proxy.scrollTo(index, anchor: .center)
                }
            }

            // CONFIRM the highlighted row. Lives OUTSIDE the ScrollView on purpose: a
            // .handGestureShortcut(.primaryAction) inside a ScrollView/List doesn't receive the
            // hardware double-pinch, so this fixed bar carries it. Tap it OR double-pinch to open.
            if items.indices.contains(index) {
                Button { commit(at: index) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("\(confirmVerb) \(title(items[index]))")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pinch)
                .handGestureShortcut(.primaryAction)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
                .accessibilityLabel("\(confirmVerb) \(title(items[index]))")
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.pinch : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(item))
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                if let sub = subtitle?(item), !sub.isEmpty {
                    Text(sub).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(selected ? Color.pinch.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 8))
    }

    /// Highlight a row (tap or crown). Keeps the crown value in sync so a following turn continues
    /// from here rather than snapping back.
    private func select(_ i: Int) {
        guard items.indices.contains(i) else { return }
        index = i
        value = Double(i)
        WKInterfaceDevice.current().play(.click)
    }

    private func commit(at i: Int) {
        guard items.indices.contains(i) else { return }
        WKInterfaceDevice.current().play(.success)
        onCommit(items[i])
    }
}
