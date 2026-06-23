//
//  RootView.swift
//  Ties the screens together. The main screen is the transcript with a fixed bottom
//  composer; a connection/status indicator sits in the nav bar; toolbar buttons open
//  mode, projects, and settings. When the agent is waiting on an approval, the composer
//  slot swaps for a NON-blocking permission bar — the transcript stays visible and
//  crown-scrollable above it (see ConversationScreen).
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: PinchStore
    @State private var showSettings = false
    @State private var showHub = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ConversationScreen()
            }
            // No navigationTitle — the app name is dead weight on a tiny screen, and the
            // system clock the OS draws at the very top can't be removed by an app anyway.
            // watchOS only renders ONE leading + ONE trailing toolbar item, so the top bar is:
            //   leading  = folder (Projects) with a small connection dot riding on it
            //   trailing = gear (Settings)
            // Mode + the rest of the composer controls live in the bottom bar.
            .toolbar {
                // Both top icons hide while the chrome is collapsed (swipe-down) so the transcript
                // owns the entire screen — only the OS clock the system draws remains. Swipe up (or
                // the orange chevron) brings them back.
                ToolbarItem(placement: .topBarLeading) {
                    if !store.chromeCollapsed {
                        Button {
                            Haptics.click()
                            store.listProjects()   // prefetch so the hub's folder picker is warm
                            showHub = true
                        } label: {
                            Image(systemName: "folder")
                                .overlay(alignment: .topTrailing) {
                                    // Connection status dot — kept visible up top per spec.
                                    Circle()
                                        .fill(ConnectionBadge.color(state: store.connection, agent: store.agentState))
                                        .frame(width: 7, height: 7)
                                        .offset(x: 5, y: -4)
                                }
                        }
                        .accessibilityLabel("Agents and folders")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.chromeCollapsed {
                        Button { Haptics.click(); showSettings = true } label: {
                            Image(systemName: "gearshape")
                                // Context-window usage rides as a thin ring AROUND the gear (a
                                // horizontal bar can't live between the toolbar items on watchOS —
                                // no center region under the clock). Fills clockwise from the top,
                                // green→red along the arc. Hidden until there's a reading.
                                .overlay { ContextRing(fraction: store.contextFraction) }
                        }
                        .accessibilityLabel(store.contextWindow > 0
                            ? "Settings. Context \(Int((store.contextFraction * 100).rounded())) percent full."
                            : "Settings")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHub) { HubView() }
        }
        // Orange is applied per-control (send, mic, bubbles), NOT globally — a global tint
        // turns watchOS 26's toolbar buttons into solid orange blobs. Keep nav icons neutral.
    }
}

extension Color {
    /// Claude's signature warm coral-orange. The single accent for the whole app,
    /// against the watch's black background (the Claude Code look).
    static let pinch = Color(red: 0.85, green: 0.47, blue: 0.34)   // ≈ #D9785A
}

/// Thin context-window usage ring that wraps the gear icon. Fills CLOCKWISE from 12 o'clock
/// as the conversation fills the model's context window, its color sweeping green→amber→red
/// along the arc. Sized just OUTSIDE the gear glyph so it never covers it; hidden at 0.
private struct ContextRing: View {
    let fraction: Double   // 0…1

    var body: some View {
        if fraction <= 0 {
            EmptyView()
        } else {
            ZStack {
                // Faint full-circle track so the "remaining" portion still reads as a ring.
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1.6)
                // Filled arc — trimmed to the fill amount, swept green→red along its length.
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(fraction, 0.03), 1)))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [.green, .yellow, .orange, .red]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))   // move the start to 12 o'clock
            }
            // ~30pt sits in the gap between the gear glyph (~22pt) and its button circle
            // (~37pt): wraps the icon without covering it, and stays inside the button.
            .frame(width: 30, height: 30)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.4), value: fraction)
        }
    }
}

/// The transcript + fixed composer, laid out so the composer never scrolls (double-tap
/// requires the primary action to live outside a ScrollView/List).
private struct ConversationScreen: View {
    @EnvironmentObject private var store: PinchStore

    var body: some View {
        VStack(spacing: 0) {
            // Transcript fills the top whenever it's visible. It's hidden ONLY when the input is
            // expanded to own the whole screen — but a pending permission overrides that, because you
            // must be able to scroll the chat to judge the request.
            if store.pendingPermission != nil || !store.inputOwnsCrown {
                TranscriptView()
                    .frame(maxHeight: .infinity)
            }

            // Bottom slot: the permission decision BAR while the agent is waiting on you, otherwise
            // the normal composer. The bar is NOT crown-focusable, so the crown keeps scrolling the
            // transcript above — a request can never hijack your scroll or answer itself.
            if let req = store.pendingPermission {
                PermissionCardView(request: req)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ComposerView()             // fixed bottom bar — holds the .primaryAction Send.
                    .frame(maxHeight: store.inputOwnsCrown ? .infinity : nil)
            }
        }
        .animation(.snappy, value: store.inputOwnsCrown)
        .animation(.snappy, value: store.chromeCollapsed)
        .animation(.snappy, value: store.pendingPermission)
        // Extend the whole stack into the bottom safe area so the button row reaches the
        // physical bottom edge (it was floating ~1/8" high when the ignore was scoped to just
        // the HStack — a nested ignoresSafeArea doesn't push past the parent VStack's layout).
        // The outer buttons' rounded outer-bottom corners keep them clear of the screen curve.
        .ignoresSafeArea(.container, edges: .bottom)
        // Chrome collapse/expand has TWO affordances: a vertical FINGER SWIPE over the transcript
        // (swipe down to hide the composer, up to bring it back — see TranscriptView's gesture),
        // plus the orange chevron BUTTONS in ComposerView as a discoverable fallback. The swipe is
        // reliable now because the transcript is scrollDisabled (crown-only scroll), so there's no
        // scroll pan to fight the drag — the reason earlier over-the-transcript swipes were dropped.
    }
}

/// Compact connection + agent-state indicator for the nav bar.
struct ConnectionBadge: View {
    let state: ConnectionState
    let agent: AgentState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            if let label = stateLabel {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(accessibility)
    }

    private var color: Color { ConnectionBadge.color(state: state, agent: agent) }

    /// Shared connection-color logic so the top-bar folder dot matches the badge.
    static func color(state: ConnectionState, agent: AgentState) -> Color {
        switch state {
        case .ready:
            switch agent {
            case .idle: return .green
            case .thinking, .running_tool: return .blue
            case .waiting_permission: return .orange
            case .error: return .red
            }
        case .connected, .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var stateLabel: String? {
        switch state {
        case .connecting: return "…"
        case .connected: return "auth"
        case .reconnecting(let n): return "retry \(n)"
        case .failed: return "offline"
        case .disconnected: return "offline"
        case .ready:
            switch agent {
            case .thinking: return "thinking"
            case .running_tool: return "running"
            case .waiting_permission: return "approve?"
            case .error: return "error"
            case .idle: return nil
            }
        }
    }

    private var accessibility: String {
        switch state {
        case .ready: return "Connected, agent \(agent.rawValue)"
        case .failed(let m): return "Connection failed: \(m)"
        default: return "Connection \(String(describing: state))"
        }
    }
}
