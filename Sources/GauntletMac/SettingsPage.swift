import SwiftUI
import GauntletLink
import GauntletEngine
import GauntletDojo

struct SettingsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UI.spacing) {
                PageHeader(title: "Settings", subtitle: "Make the pointer feel like yours.") {
                    Button { model.resetSettings() } label: { Label("Restore Defaults", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(FlareButtonStyle(kind: .secondary))
                }

                pointerFeel

                HStack(alignment: .top, spacing: UI.spacing) {
                    VStack(spacing: UI.spacing) {
                        control
                        watch
                    }
                    VStack(spacing: UI.spacing) {
                        scrolling
                        advanced
                    }
                }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.bottom, UI.pagePadding)
        }
        .scrollIndicators(.never)
    }

    // MARK: Pointer feel

    private var pointerFeel: some View {
        Panel("Pointer feel") {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 10) {
                    inset(title: "Pointer response", note: "Drag the sliders — the curve follows") {
                        ResponseCurve(settings: model.settings).frame(height: 168)
                    }
                    inset(title: "Tremor filter", legend: true) {
                        TremorPreview(smoothing: model.settings.smoothing).frame(height: 52)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 0) {
                    SliderSetting(symbol: "gauge.with.dots.needle.50percent", title: "Speed",
                                  value: $model.settings.sensitivity, range: 0.3...3.0) { String(format: "%.1f×", $0) }
                    SliderSetting(symbol: "water.waves", title: "Steadiness",
                                  detail: "Filters out hand tremor; higher feels slightly softer",
                                  value: $model.settings.smoothing, range: 0...1) { String(format: "%.0f%%", $0 * 100) }
                    SliderSetting(symbol: "scope", title: "Fine control",
                                  detail: "How much slow movement is scaled down for precision",
                                  value: $model.settings.precisionMultiplier, range: 0.15...1.0) { String(format: "%.2f×", $0) }
                    SliderSetting(symbol: "arrow.left.and.right", title: "Sweep boost",
                                  detail: "How much fast swings are amplified to cross the screen",
                                  value: $model.settings.boostMultiplier, range: 1.0...4.0) { String(format: "%.1f×", $0) }
                    HStack(spacing: 16) {
                        compactToggle("arrow.left.arrow.right", "Reverse left and right", $model.settings.invertX)
                        compactToggle("arrow.up.arrow.down", "Reverse up and down", $model.settings.invertY)
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func inset<C: View>(title: String, note: String? = nil, legend: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(UI.ink)
                Spacer()
                if let note { Text(note).font(UI.small).foregroundStyle(UI.ink3) }
                if legend {
                    HStack(spacing: 10) {
                        legendItem(UI.ink3, "Your hand")
                        legendItem(UI.flare, "Pointer")
                    }
                }
            }
            content()
        }
        .padding(12)
        .background(UI.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UI.hairline, lineWidth: 0.75))
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 2)
            Text(text).font(UI.small).foregroundStyle(UI.ink2)
        }
    }

    private func compactToggle(_ symbol: String, _ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol)
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.ink).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            FlareSwitch(isOn: isOn)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Cards

    private var control: some View {
        Panel("Taking and releasing control") {
            VStack(spacing: 0) {
                SettingRow(symbol: "hand.raised", title: "Pointer follows your arm", showsDivider: false) {
                    Segmented(selection: $model.settings.clutch,
                              options: ClutchMode.allCases.map { (value: $0, label: $0.title) })
                }
                Text(model.settings.clutch == .raiseToPoint
                     ? "Lift your forearm above the angle to take control; lower it to the keyboard to let go."
                     : "The pointer follows your arm whenever it is not hanging at your side.")
                    .font(UI.caption).foregroundStyle(UI.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                Rectangle().fill(UI.hairline).frame(height: 1)
                if model.settings.clutch == .raiseToPoint {
                    SliderSetting(symbol: "angle", title: "Lift angle",
                                  value: $model.settings.raiseAngleDeg, range: -10...35) { String(format: "%.0f°", $0) }
                }
                ToggleSetting(symbol: "keyboard", title: "Hold still while typing",
                              detail: "Like a trackpad's palm rejection", isOn: $model.typingGuardEnabled, showsDivider: false)
            }
        }
    }

    private var watch: some View {
        Panel("Watch") {
            VStack(spacing: 0) {
                ToggleSetting(symbol: "waveform.path", title: "Haptic feedback", isOn: $model.settings.hapticsEnabled)
                ToggleSetting(symbol: "arrow.left.arrow.right.square", title: "Watch is worn the other way round",
                              detail: "Calibration sets this. Flip it by hand only if up and down feel reversed.",
                              isOn: $model.settings.forearmAxisFlipped, showsDivider: !model.trustedWatches.isEmpty)
                ForEach(Array(model.trustedWatches.enumerated()), id: \.element.id) { index, watch in
                    SettingRow(symbol: "checkmark.shield", title: watch.name,
                               detail: "Paired \(watch.pairedAt.formatted(date: .abbreviated, time: .shortened))",
                               showsDivider: index < model.trustedWatches.count - 1) {
                        Button("Forget") { model.forget(watch) }.buttonStyle(FlareButtonStyle(kind: .destructive, compact: true))
                    }
                }
            }
        }
    }

    private var scrolling: some View {
        Panel("Scrolling and touch") {
            VStack(spacing: 0) {
                SliderSetting(symbol: "digitalcrown.horizontal.arrow.clockwise", title: "Digital Crown speed",
                              value: $model.settings.crownScrollGain, range: 200...2500) { String(format: "%.0f", $0) }
                SliderSetting(symbol: "wind", title: "Air-scroll speed",
                              value: $model.settings.airScrollGain, range: 400...4000) { String(format: "%.0f", $0) }
                SliderSetting(symbol: "applewatch", title: "Watch-face trackpad speed",
                              value: $model.settings.touchGain, range: 0.8...6) { String(format: "%.1f×", $0) }
                ToggleSetting(symbol: "arrow.up.arrow.down", title: "Reverse scroll direction",
                              isOn: $model.settings.scrollInverted, showsDivider: false)
            }
        }
    }

    private var advanced: some View {
        Panel("Advanced") {
            VStack(spacing: 0) {
                SettingRow(symbol: model.accessibilityGranted ? "checkmark.seal" : "exclamationmark.triangle",
                           title: model.accessibilityGranted ? "Accessibility permission granted" : "Accessibility permission missing",
                           detail: testDetail) {
                    if model.accessibilityGranted {
                        Button("Test Pointer") { model.testPointer() }.buttonStyle(FlareButtonStyle(kind: .secondary, compact: true))
                    } else {
                        Button("Open Settings") { model.requestAccessibility() }.buttonStyle(FlareButtonStyle(kind: .primary, compact: true))
                    }
                }
                ToggleSetting(symbol: "hammer", title: "Developer link",
                              detail: "Accepts a simulated watch (watchOS Simulator, fakewatch) from this Mac only. Leave it off for everyday use.",
                              isOn: $model.developerLinkEnabled, showsDivider: false)
            }
        }
    }

    private var testDetail: String? {
        switch model.pointerTestPassed {
        case .some(true): return "Pointer moved ✓"
        case .some(false): return "macOS ignored the test. Remove Flare from the Accessibility list, add it again, relaunch."
        case .none: return model.accessibilityGranted ? nil : "Needed before Flare can move the real cursor"
        }
    }
}

// MARK: - Pointer response chart

/// How much the pointer moves per unit of arm movement, from slow (fine control) to fast (sweep boost).
private struct ResponseCurve: View {
    var settings: EngineSettings

    private func gain(_ x: Double) -> Double {
        func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double {
            let t = min(1, max(0, (v - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        let precision = settings.precisionMultiplier
        let shape = precision + (1 - precision) * smooth(0.06, 0.36, x) + (settings.boostMultiplier - 1) * smooth(0.56, 0.9, x)
        return settings.sensitivity * shape
    }

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 26, bottom: CGFloat = 20, top: CGFloat = 20
            let plot = CGRect(x: left, y: top, width: size.width - left - 4, height: size.height - top - bottom)
            let peak = gain(1)
            let ceiling = max(8, (peak / 2).rounded(.up) * 2)
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: plot.minX + CGFloat(x) * plot.width, y: plot.maxY - CGFloat(y / ceiling) * plot.height)
            }
            // Zones.
            let zones: [(String, Double, Double, Bool)] = [("Fine control", 0, 0.34, true), ("Speed", 0.34, 0.62, false), ("Sweep boost", 0.62, 1, true)]
            for zone in zones {
                let rect = CGRect(x: pt(zone.1, 0).x, y: plot.minY, width: CGFloat(zone.2 - zone.1) * plot.width, height: plot.height)
                if zone.3 { context.fill(Path(rect), with: .color(Color.black.opacity(0.035))) }
                context.draw(Text(zone.0).font(.system(size: 10, weight: .medium)).foregroundColor(UI.ink2),
                             at: CGPoint(x: rect.midX, y: plot.minY - 10))
            }
            // Grid and y labels.
            let step = ceiling / 4
            for i in 0...4 {
                let v = Double(i) * step
                let y = pt(0, v).y
                var g = Path()
                g.move(to: CGPoint(x: plot.minX, y: y))
                g.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(g, with: .color(Color.black.opacity(0.06)), lineWidth: 1)
                context.draw(Text(String(format: "%.0f×", v)).font(.system(size: 9)).foregroundColor(UI.ink3),
                             at: CGPoint(x: plot.minX - 12, y: y))
            }
            context.draw(Text("Slow").font(.system(size: 9.5)).foregroundColor(UI.ink2), at: CGPoint(x: plot.minX + 12, y: plot.maxY + 11))
            context.draw(Text("Arm speed").font(.system(size: 9.5)).foregroundColor(UI.ink2), at: CGPoint(x: plot.midX, y: plot.maxY + 11))
            context.draw(Text("Fast").font(.system(size: 9.5)).foregroundColor(UI.ink2), at: CGPoint(x: plot.maxX - 12, y: plot.maxY + 11))

            // Curve.
            var line = Path()
            let samples = 80
            for i in 0...samples {
                let x = Double(i) / Double(samples)
                let p = pt(x, gain(x))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var area = line
            area.addLine(to: pt(1, 0))
            area.addLine(to: pt(0, 0))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [UI.flare.opacity(0.22), UI.flare.opacity(0.02)]),
                                                     startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            context.stroke(line, with: .color(UI.flare), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            for x in [0.04, 0.47, 0.97] {
                let p = pt(x, gain(x))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(UI.ink))
            }
        }
        .animation(.easeOut(duration: 0.2), value: settings)
    }
}

/// A shaky hand signal and what the pointer makes of it at the current steadiness.
private struct TremorPreview: View {
    var smoothing: Double

    private static let hand: [Double] = {
        var rng = Lcg(seed: 7)
        return (0..<120).map { i in
            let t = Double(i) / 120
            return sin(t * 9) * 0.25 + sin(t * 23 + 1) * 0.12 + (rng.next() - 0.5) * 0.5
        }
    }()

    var body: some View {
        Canvas { context, size in
            let values = Self.hand
            let alpha = max(0.06, 1 - smoothing * 0.92)
            var filtered: [Double] = []
            var last = values[0]
            for v in values {
                last += alpha * (v - last)
                filtered.append(last)
            }
            func path(_ series: [Double]) -> Path {
                var p = Path()
                for (i, v) in series.enumerated() {
                    let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(series.count - 1),
                                     y: size.height / 2 - CGFloat(v) * size.height * 0.75)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            context.stroke(path(values), with: .color(UI.ink3.opacity(0.8)), lineWidth: 1)
            context.stroke(path(filtered), with: .color(UI.flare), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }
}

/// Tiny deterministic random numbers so the preview never jumps between redraws.
private struct Lcg {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
}
