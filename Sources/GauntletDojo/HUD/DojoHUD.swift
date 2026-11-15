import SwiftUI
import GauntletEngine

/// The Dojo page in Flare's layout: header, activity tabs, the 3D sandbox in a card with the
/// live sensors and the current activity beside it, and the controls cheat sheet underneath.
struct DojoHUD: View {
    @ObservedObject var controller: DojoController

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                DojoHeader(controller: controller)
                ModeTabs(controller: controller)
                HStack(alignment: .top, spacing: 16) {
                    SceneCard(controller: controller)
                    ScrollView {
                        VStack(spacing: 14) {
                            SensorPanel(trace: controller.trace, link: controller.link)
                            ActivityPanel(mode: controller.mode, status: controller.status,
                                          virtualWatch: controller.link.virtualWatch) { controller.perform($0) }
                        }
                        .padding(.bottom, 2)
                    }
                    .scrollIndicators(.never)
                    .frame(width: 290)
                }
                .frame(maxHeight: .infinity)
                if controller.showHelp {
                    HelpPanel(virtualWatch: controller.link.virtualWatch || !controller.link.realWatch)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 20)

            if controller.showStats {
                StatsSheet(controller: controller)
            }
        }
        .onAppear { controller.setInsets(CameraRig.Insets(left: 0, right: 0, top: 52, bottom: 44)) }
    }
}

// MARK: - Header

private struct DojoHeader: View {
    @ObservedObject var controller: DojoController

    var body: some View {
        let link = controller.link
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Dojo").font(.system(size: 28, weight: .bold)).foregroundStyle(DojoTheme.textPrimary)
                Text("Practise every gesture in a sandbox. Nothing here touches your Mac.")
                    .font(.system(size: 13)).foregroundStyle(DojoTheme.textSecondary)
            }
            Spacer(minLength: 12)

            wristSwitch(link)
                .help(link.realWatch ? "Wrist reported by your watch" : "Which wrist the virtual watch is worn on")

            if link.realWatch {
                Chip(text: "Apple Watch", symbol: "applewatch", tone: DojoTheme.success)
                    .help("Your Apple Watch is streaming")
            } else {
                HStack(spacing: 8) {
                    Label("Virtual watch", systemImage: "computermouse")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DojoTheme.secondary)
                    Button { controller.autopilot.toggle() } label: {
                        Label("Autopilot", systemImage: "wand.and.stars")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(controller.autopilot ? flareInk : DojoTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().fill(controller.autopilot ? DojoTheme.accent : Color.white))
                    }
                    .buttonStyle(.plain)
                    .help("Autopilot demo: let the Dojo play itself (A)")
                }
                .padding(.leading, 12)
                .padding(.trailing, 5)
                .frame(height: 32)
                .background(Capsule().fill(DojoTheme.accent.opacity(0.12)))
                .overlay(Capsule().strokeBorder(DojoTheme.accent.opacity(0.25), lineWidth: 0.75))
                .help("No watch connected — the mouse is driving a simulated one")
            }

            Button { controller.showStats.toggle() } label: { Image(systemName: "chart.bar") }
                .buttonStyle(IconButtonStyle(active: controller.showStats))
                .help("Personal bests and history")
            Button { controller.showHelp.toggle() } label: { Image(systemName: "questionmark") }
                .buttonStyle(IconButtonStyle(active: controller.showHelp))
                .help("Controls (H)")
        }
    }

    private func wristSwitch(_ link: LinkStatus) -> some View {
        let right = link.realWatch ? link.rightWrist : controller.virtualRightWrist
        return HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { isRight in
                let selected = right == isRight
                Button { controller.setVirtualWrist(right: isRight) } label: {
                    Text(isRight ? "Right wrist" : "Left wrist")
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? DojoTheme.textPrimary : DojoTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.05)))
        .disabled(link.realWatch)
    }
}

// MARK: - Tabs

private struct ModeTabs: View {
    @ObservedObject var controller: DojoController

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DojoMode.allCases) { mode in
                let selected = mode == controller.mode
                Button { controller.select(mode) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbol).font(.system(size: 11, weight: .medium))
                        Text(mode.shortTitle).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .foregroundStyle(selected ? DojoTheme.textPrimary : DojoTheme.textSecondary)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white)
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.blurb)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.black.opacity(0.05), lineWidth: 0.75))
    }
}

// MARK: - Sandbox card

private struct SceneCard: View {
    @ObservedObject var controller: DojoController

    var body: some View {
        ZStack(alignment: .top) {
            DojoSceneView(controller: controller)

            HStack(alignment: .top, spacing: 8) {
                StateBadge(flags: controller.flags, link: controller.link)
                Spacer(minLength: 8)
                EngageHint(flags: controller.flags, link: controller.link, mode: controller.mode)
            }
            .padding(12)

            ToastStack(toasts: controller.toasts)
                .padding(.top, 56)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DojoTheme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DojoTheme.panelStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 10, y: 3)
    }
}

/// "Engaged · pointer follows your arm" and friends, over the sandbox.
private struct StateBadge: View {
    var flags: PointerFlags
    var link: LinkStatus

    var body: some View {
        HStack(spacing: 6) {
            badge
            if flags.dragging { Chip(text: "Dragging", symbol: "hand.draw", tone: DojoTheme.secondary) }
            if flags.scrollMode { Chip(text: "Air-scroll", symbol: "arrow.up.arrow.down", tone: DojoTheme.success) }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if !link.streaming {
            pill("No signal", dot: DojoTheme.textSecondary)
        } else if flags.paused {
            pill("Paused", dot: DojoTheme.warning)
        } else if flags.engaged {
            pill("Engaged · pointer follows your arm", dot: DojoTheme.accent)
        } else {
            pill("Released · raise your arm to point", dot: DojoTheme.textSecondary)
        }
    }

    private func pill(_ text: String, dot: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DojoTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.92)))
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.07), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

/// Tells the user why the pointer is not moving, when it is not.
struct EngageHint: View {
    var flags: PointerFlags
    var link: LinkStatus
    var mode: DojoMode

    private var message: (text: String, symbol: String, tone: Color)? {
        if !link.streaming {
            if mode == .live, !link.realWatch { return nil }
            return ("Waiting for the watch…", "antenna.radiowaves.left.and.right", DojoTheme.textSecondary)
        }
        if flags.paused {
            return (link.virtualWatch ? "Paused — press P to resume" : "Paused — resume from your watch", "pause.circle", DojoTheme.warning)
        }
        if !flags.engaged {
            if link.virtualWatch, flags.posture == .dropped { return ("Arm lowered — press Space to raise it", "arrow.up.circle", DojoTheme.secondary) }
            if link.virtualWatch, flags.posture == .raised { return ("Arm raised — press U to bring it back", "arrow.down.circle", DojoTheme.secondary) }
            return ("Raise your forearm to point", "arrow.up.circle", DojoTheme.secondary)
        }
        return nil
    }

    var body: some View {
        if let message {
            Label(message.text, systemImage: message.symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(message.tone)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(0.92)))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.07), lineWidth: 0.75))
        }
    }
}

// MARK: - Controls

/// The always-available cheat sheet for driving the virtual watch (and the camera), in groups.
struct HelpPanel: View {
    var virtualWatch: Bool

    private var groups: [(String, [(String, String)])] {
        if virtualWatch {
            return [
                ("Arm", [("Mouse", "steer"), ("Space", "lower / raise"), ("U", "arm to ceiling")]),
                ("Gestures", [("Click", "finger tap"), ("Right-click", "flick out"), ("F", "or"), ("⌥ Click", "flick in · grab"),
                              ("Scroll", "Digital Crown"), ("S", "air-scroll")]),
                ("Session", [("P", "pause"), ("R", "recenter"), ("A", "autopilot")]),
                ("View", [("⌘ Drag", "orbit"), ("⌘ Scroll", "zoom"), ("C", "reset view"), ("H", "hide")]),
            ]
        }
        return [
            ("View", [("Drag", "orbit camera"), ("Scroll / Pinch", "zoom"), ("C", "reset view")]),
            ("Session", [("P", "pause"), ("R", "recenter"), ("H", "hide")]),
        ]
    }

    var body: some View {
        FlowLayout(spacing: 22, lineSpacing: 9) {
            ForEach(groups, id: \.0) { group in
                HStack(spacing: 8) {
                    Text(group.0).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DojoTheme.textPrimary)
                    ForEach(group.1, id: \.0) { hint in
                        KeyHint(key: hint.0, label: hint.1)
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DojoTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DojoTheme.panelStroke, lineWidth: 1))
    }
}

/// Gesture toasts: what was recognised and what it did.
struct ToastStack: View {
    var toasts: [GestureToast]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(DojoTheme.accent)
                    Text(toast.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DojoTheme.textPrimary)
                    if !toast.detail.isEmpty {
                        Image(systemName: "arrow.right").font(.system(size: 9.5, weight: .bold)).foregroundStyle(DojoTheme.textSecondary)
                        Text(toast.detail).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DojoTheme.secondary)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().strokeBorder(DojoTheme.accent.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: toasts)
    }
}
