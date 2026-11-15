import SwiftUI
import GauntletLink
import GauntletEngine
import GauntletDojo

/// `--showcase` renders the page as it looks in everyday use (no setup banners, Bluetooth label)
/// even when driven by the simulated watch. Used only for capturing demo footage.
private let showcase = CommandLine.arguments.contains("--showcase")

struct ControlPage: View {
    @ObservedObject var model: AppModel
    var openDojo: () -> Void
    var openGestures: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UI.spacing) {
                PageHeader(title: "Control", subtitle: "Lift your arm toward the screen and point. Your watch is the mouse.") {
                    HeaderButtons(model: model, telemetry: model.telemetry)
                }

                banners

                if model.isConnected {
                    LiveStatusCard(model: model, telemetry: model.telemetry)
                    HStack(alignment: .top, spacing: UI.spacing) {
                        SignalCard(model: model, telemetry: model.telemetry)
                        RecentCard(model: model).frame(width: 310)
                    }
                    HowToDrive(model: model, openGestures: openGestures)
                } else {
                    WaitingHero(model: model, openDojo: openDojo)
                    SetupSteps()
                }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.bottom, UI.pagePadding)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var banners: some View {
        if !model.accessibilityGranted, !showcase {
            Banner(symbol: "hand.raised", title: "Allow Flare to control the pointer",
                   text: "macOS needs the Accessibility permission before any app can move the cursor. Until then everything works in the Dojo sandbox only.",
                   tone: .amber, action: "Open Settings") { model.requestAccessibility() }
        }
        if !model.bluetoothConfigured, !showcase {
            Banner(symbol: "antenna.radiowaves.left.and.right.slash", title: "Bluetooth is off for this run",
                   text: CommandLine.arguments.contains("--no-bluetooth")
                       ? "Started with --no-bluetooth. Relaunch normally to connect a real watch."
                       : "Launch the installed app in ~/Applications to connect a real watch.",
                   tone: .amber)
        }
        if model.isConnected, !model.settings.calibrated, !showcase {
            Banner(symbol: "scope", title: "Calibrate before first use",
                   text: "Two minutes in the Dojo teaches Flare how you wear the watch and how hard you tap.",
                   action: "Open the Dojo", perform: openDojo)
        }
    }
}

// MARK: - Header

private struct HeaderButtons: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        let paused = telemetry.snapshot.paused
        HStack(spacing: 8) {
            Button { model.recenter() } label: { Label("Recenter", systemImage: "scope") }
                .buttonStyle(FlareButtonStyle(kind: .secondary))
            Button { model.togglePause() } label: {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(FlareButtonStyle(kind: model.isConnected ? .primary : .secondary))
        }
    }
}

// MARK: - Live status

/// Watch, elevation and wrist twist side by side (stacked when the window is narrow).
private struct LiveStatusCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        let s = telemetry.snapshot
        Surface(padding: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    watchSection(s).frame(minWidth: 330, maxWidth: .infinity, alignment: .topLeading)
                    divider(vertical: true)
                    elevationSection(s).frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
                    divider(vertical: true)
                    twistSection(s).frame(minWidth: 290, maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        watchSection(s).frame(maxWidth: .infinity, alignment: .topLeading)
                        divider(vertical: true)
                        elevationSection(s).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    divider(vertical: false)
                    twistSection(s).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func divider(vertical: Bool) -> some View {
        Rectangle().fill(UI.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }

    // Watch

    private struct Look {
        var title: String
        var detail: String
    }

    private func look(_ s: WristSnapshot) -> Look {
        if s.paused { return Look(title: "Paused", detail: "Resume here or from your watch.") }
        if model.sandboxActive { return Look(title: "In the Dojo", detail: "Pointer output stays in the sandbox.") }
        if s.dragging { return Look(title: "Dragging", detail: "Flick in again to drop.") }
        if s.scrollMode { return Look(title: "Air-scrolling", detail: "Tilt your forearm to scroll.") }
        if s.engaged { return Look(title: "Pointing", detail: "Arm raised — the pointer follows you.") }
        return Look(title: "Ready", detail: "Lift your arm to take the pointer.")
    }

    private func watchSection(_ s: WristSnapshot) -> some View {
        let l = look(s)
        let name: String = {
            if case .connected(let name, _) = model.link { return name }
            return "Apple Watch"
        }()
        let via: String = {
            if case .connected(_, let via) = model.link { return showcase ? "Bluetooth" : via }
            return ""
        }()
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                StatusChip(text: "Connected", tone: .green, dot: true).fixedSize()
                Spacer(minLength: 6)
                if let hr = s.heartRate {
                    Label("\(hr)", systemImage: "heart.fill").labelStyle(TightLabelStyle())
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(UI.ink2)
                }
                Text(name).font(.system(size: 12)).foregroundStyle(UI.ink2).lineLimit(1)
                Menu {
                    if !via.isEmpty { Text("Connected over \(via)") }
                    Button("Disconnect") { model.disconnectWatch() }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(UI.ink3)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            HStack(spacing: 18) {
                WatchIllustration(width: 70) {
                    WatchScreen(engaged: s.engaged && !s.paused, degrees: s.elevation * 180 / .pi, streaming: s.streaming)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(l.title).font(.system(size: 26, weight: .bold)).foregroundStyle(UI.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(l.detail).font(UI.body).foregroundStyle(UI.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.25), value: l.title)
            HStack(spacing: 8) {
                StatBox(label: "Battery", value: s.battery.map { "\($0)%" } ?? "–",
                        tint: (s.battery ?? 100) <= 15 ? UI.red : UI.ink)
                StatBox(label: "Wrist", value: s.rightWrist ? "Right" : "Left")
                StatBox(label: "Follows", value: model.settings.clutch == .always ? "Always" : "When raised")
            }
        }
        .padding(20)
    }

    // Elevation

    private func elevationSection(_ s: WristSnapshot) -> some View {
        let raise = model.settings.clutch == .raiseToPoint
        let threshold = raise ? model.settings.raiseAngleDeg : model.settings.restAngleDeg
        let degrees = s.elevation * 180 / .pi
        let valid = s.streaming && s.poseValid
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Elevation").font(UI.cardTitle).foregroundStyle(UI.ink)
                Spacer()
                StatusChip(text: s.engaged ? "Engaged" : "Resting", tone: s.engaged ? .flare : .neutral)
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(valid ? String(format: "%.0f°", degrees) : "–")
                        .font(.system(size: 44, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(UI.ink)
                        .contentTransition(.numericText())
                    Text(raise ? "Clutch engages when your arm rises above \(Int(threshold.rounded()))°"
                               : "The pointer follows unless your arm hangs below \(Int(threshold.rounded()))°")
                        .font(UI.caption).foregroundStyle(UI.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 170, alignment: .leading)
                Spacer(minLength: 0)
                ElevationDial(degrees: degrees, threshold: threshold, engaged: s.engaged, valid: valid)
                    .frame(width: 150, height: 196)
            }
        }
        .padding(20)
    }

    // Twist

    private func twistSection(_ s: WristSnapshot) -> some View {
        let tuning = model.settings.gestures
        let degrees = s.roll * 180 / .pi
        let valid = s.streaming && s.poseValid
        let rate = abs(s.rates.z)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Wrist twist").font(UI.cardTitle).foregroundStyle(UI.ink)
                Spacer()
                StatusChip(text: tuning.flickEnabled ? "Flicks on" : "Flicks off", tone: .neutral)
            }
            HStack(alignment: .center, spacing: 8) {
                Text(valid ? String(format: "%+.0f°", degrees) : "–")
                    .font(.system(size: 44, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(UI.ink)
                    .contentTransition(.numericText())
                    .frame(minWidth: 96, alignment: .leading)
                Spacer(minLength: 0)
                TwistGauge(degrees: degrees, valid: valid)
                    .frame(width: 170, height: 104)
            }
            .padding(.top, 14)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Flick speed").font(UI.caption).foregroundStyle(UI.ink2)
                    Spacer()
                    Text(String(format: "%.1f / %.1f rad/s", s.streaming ? rate : 0, tuning.flickRate))
                        .font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(UI.ink)
                }
                MeterBar(value: s.streaming ? rate : 0, marker: tuning.flickRate, ceiling: max(1, tuning.flickRate * 1.6))
            }
            .padding(.top, 8)
        }
        .padding(20)
    }
}

/// What the little watch in the status card shows: the Flare ring and a pointer.
private struct WatchScreen: View {
    var engaged: Bool
    var degrees: Double
    var streaming: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: engaged ? 0.78 : 0.3)
                    .stroke(engaged ? UI.flare : Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "cursorarrow")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            Text(streaming ? String(format: "%.0f°", degrees) : "–")
                .font(.system(size: 7.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
        .animation(.easeInOut(duration: 0.3), value: engaged)
    }
}

// MARK: - Signal

private struct SignalCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        let s = telemetry.snapshot
        let threshold = model.settings.gestures.tapThreshold
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Signal").font(UI.cardTitle).foregroundStyle(UI.ink)
                    StatusChip(text: s.streaming ? "Live" : "Idle", tone: s.streaming ? .flare : .neutral, dot: true)
                    Spacer()
                    figure(s.streaming ? String(format: "%.0f", s.packetRate) : "–", "packets/s")
                    figure(s.streaming ? String(format: "%.1f%%", s.packetLoss * 100) : "–", "loss",
                           warn: s.packetLoss > 0.1)
                }
                HStack {
                    Text("Tap energy").font(UI.caption).foregroundStyle(UI.ink2)
                    Spacer()
                    HStack(spacing: 5) {
                        DashSwatch()
                        Text(String(format: "Clicks above %.2f g", threshold)).font(UI.small).foregroundStyle(UI.ink2)
                    }
                }
                LineChart(values: telemetry.tapHistory, ceiling: max(0.4, threshold * 2.2), color: UI.ink, threshold: threshold)
                    .frame(height: 96)
                HStack {
                    Text("Pointer speed").font(UI.caption).foregroundStyle(UI.ink2)
                    Spacer()
                    Text("Last 6 s").font(UI.small).foregroundStyle(UI.ink3)
                }
                .padding(.top, 2)
                LineChart(values: telemetry.speedHistory, ceiling: 2500, color: UI.blue, fill: true, lineWidth: 1.6)
                    .frame(height: 58)
            }
        }
    }

    private func figure(_ value: String, _ unit: String, warn: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(warn ? UI.amber : UI.ink)
            Text(unit).font(.system(size: 11.5)).foregroundStyle(UI.ink2)
        }
        .padding(.leading, 6)
    }
}

// MARK: - Recent

private struct RecentCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent").font(UI.cardTitle).foregroundStyle(UI.ink)
                    Spacer()
                    if !model.log.isEmpty {
                        Button("Clear") { model.clearLog() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(UI.ink2)
                    }
                }
                if model.log.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.tap").font(.system(size: 20)).foregroundStyle(UI.ink3)
                        Text("Gestures you make appear here.").font(UI.caption).foregroundStyle(UI.ink2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 2) {
                            ForEach(Array(model.log.prefix(6).enumerated()), id: \.element.id) { index, entry in
                                row(entry, first: index == 0, now: context.date)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ entry: GestureLogEntry, first: Bool, now: Date) -> some View {
        let action = entry.detail.isEmpty ? entry.title : entry.detail
        let gesture = entry.detail.isEmpty ? "No action assigned" : entry.title
        return HStack(spacing: 10) {
            IconTile(symbol: entry.symbol, highlighted: first, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(action).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.ink).lineLimit(1)
                Text(gesture).font(UI.small).foregroundStyle(UI.ink2).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Self.ago(entry.date, now: now))
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(first ? UI.ink : UI.ink3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(first ? UI.well : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

// MARK: - How to drive

/// A cheat sheet that always reflects the current bindings.
private struct HowToDrive: View {
    @ObservedObject var model: AppModel
    var openGestures: () -> Void

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How to drive").font(UI.cardTitle).foregroundStyle(UI.ink)
                        Text("What each gesture does right now.").font(UI.caption).foregroundStyle(UI.ink2)
                    }
                    Spacer()
                    LinkButton(title: "Edit in Gestures", action: openGestures)
                }
                let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) {
                    tile("arrow.up.right", "Lift & swing your arm", "Move pointer")
                    tile("hand.pinch", "Tap thumb and finger", bound(.pinchTap))
                    tile("digitalcrown.horizontal.arrow.clockwise", "Turn the Digital Crown", "Scroll")
                    tile("arrow.up.and.down.and.arrow.left.and.right", "Drag on the watch face", "Fine pointer")
                    tile("arrow.clockwise", "Flick wrist outward", bound(.flickOut))
                    tile("arrow.counterclockwise", "Flick wrist inward", bound(.flickIn))
                }
            }
        }
    }

    /// nil when the gesture does nothing yet.
    private func bound(_ gesture: GestureKind) -> String? {
        let action = model.settings.action(for: gesture)
        return action == .none ? nil : action.title
    }

    private func tile(_ symbol: String, _ gesture: String, _ result: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UI.ink2)
                .frame(width: 22)
            Text(gesture).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            if let result {
                Text(result)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UI.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UI.line, lineWidth: 0.75))
            } else {
                Button("Assign", action: openGestures)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UI.ember)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UI.flare.opacity(0.55), lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(UI.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UI.hairline, lineWidth: 0.75))
    }
}

// MARK: - Waiting

/// The whole page while no watch is connected: find it, pair it, or practise without it.
private struct WaitingHero: View {
    @ObservedObject var model: AppModel
    var openDojo: () -> Void

    var body: some View {
        Surface(padding: 0) {
            ZStack {
                // Warm glow and rings around the watch.
                GeometryReader { proxy in
                    let center = CGPoint(x: proxy.size.width / 2, y: 120)
                    ZStack {
                        RadialGradient(colors: [UI.flare.opacity(0.16), UI.flare.opacity(0.04), .clear],
                                       center: UnitPoint(x: 0.5, y: 120 / max(1, proxy.size.height)),
                                       startRadius: 0, endRadius: 360)
                        ForEach(0..<3) { i in
                            Circle()
                                .strokeBorder(UI.flare.opacity(0.14 - Double(i) * 0.035), lineWidth: 1)
                                .frame(width: 170 + CGFloat(i) * 80, height: 170 + CGFloat(i) * 80)
                                .position(center)
                        }
                    }
                }
                .allowsHitTesting(false)

                VStack(spacing: 14) {
                    WatchIllustration(width: 64) {
                        VStack(spacing: 4) {
                            FlareMark().fill(UI.flare).frame(width: 34, height: 34 / FlareMark.aspect)
                            Text("Flare").font(.system(size: 7, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(.top, 34)
                    content
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.link {
        case .awaitingApproval(let name, let code):
            StatusChip(text: "Pairing request", tone: .amber, dot: true)
            Text("Pair with \(name)?").font(.system(size: 26, weight: .bold)).foregroundStyle(UI.ink)
            Text(code)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .foregroundStyle(UI.ember)
            Text("Approve only if your watch shows exactly this code.")
                .font(UI.body).foregroundStyle(UI.ink2)
            HStack(spacing: 8) {
                Button("Decline") { model.rejectPairing() }.buttonStyle(FlareButtonStyle(kind: .secondary))
                Button("Pair") { model.approvePairing() }
                    .buttonStyle(FlareButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        case .handshaking:
            StatusChip(text: "Securing the link", tone: .neutral, spinning: true)
            Text("Connecting to your watch").font(.system(size: 26, weight: .bold)).foregroundStyle(UI.ink)
            Text("Verifying the watch's identity.").font(UI.body).foregroundStyle(UI.ink2)
        case .waiting(let status), .connected(let status, _):
            StatusChip(text: "Looking for your watch", tone: .neutral, spinning: true)
            Text("Waiting for your watch").font(.system(size: 26, weight: .bold)).foregroundStyle(UI.ink)
            Text("Open Flare on your Apple Watch and keep it within a few metres. Control starts the moment it connects.")
                .font(UI.body).foregroundStyle(UI.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button(action: openDojo) { Label("Try the Dojo in virtual mode", systemImage: "cube") }
                    .buttonStyle(FlareButtonStyle(kind: .secondary))
                Text("No watch handy? Practise with your mouse.").font(UI.caption).foregroundStyle(UI.ink3)
            }
            .padding(.top, 4)
            if Self.worthShowing(status) {
                Text(status).font(UI.small).foregroundStyle(UI.ink3).multilineTextAlignment(.center)
            }
        }
    }

    /// Transport messages that tell the user something (not the generic "starting" one).
    private static func worthShowing(_ status: String) -> Bool {
        !status.isEmpty && status != "Starting…" && !status.hasPrefix("Waiting for your watch")
    }
}

private struct SetupSteps: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            step(1, "Open Flare on your watch", "Launch it from the app list on your Apple Watch.")
            step(2, "Stay within a few metres", "Keep your watch close to this Mac while it connects.")
            step(3, "Raise your arm to point", "The pointer follows whenever your arm isn't hanging at your side.")
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        Surface(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(number == 1 ? UI.ember : UI.ink2)
                    .frame(width: 22, height: 22)
                    .background(number == 1 ? UI.flareTint : Color.black.opacity(0.05), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.ink)
                    Text(detail).font(UI.caption).foregroundStyle(UI.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
