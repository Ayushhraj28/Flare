import SwiftUI
import GauntletEngine
import GauntletDojo

struct GesturesPage: View {
    @ObservedObject var model: AppModel
    var openDojo: () -> Void
    @LocalState private var selected: GestureKind = .pinchTap

    private let handsFree: [GestureKind] = [.pinchTap, .flickOut, .flickIn, .handDoubleTap, .dwell]
    private let watchFace: [GestureKind] = [.screenTap, .screenLongPress]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Gestures", subtitle: "Choose what each gesture does, and how eagerly it is recognised.") {
                    Button(action: openDojo) { Label("Calibrate in Dojo", systemImage: "cube") }
                        .buttonStyle(FlareButtonStyle(kind: .secondary))
                }

                HStack(alignment: .top, spacing: UI.spacing) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("Hands-free")
                        list(handsFree)
                        sectionLabel("On the watch face").padding(.top, 8)
                        list(watchFace)
                    }
                    .frame(maxWidth: .infinity)

                    GestureDetail(model: model, telemetry: model.telemetry, gesture: selected, openDojo: openDojo)
                        .frame(width: 340)
                }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.bottom, UI.pagePadding)
        }
        .scrollIndicators(.never)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.ink2).padding(.leading, 4)
    }

    private func list(_ gestures: [GestureKind]) -> some View {
        Surface(padding: 6) {
            VStack(spacing: 2) {
                ForEach(gestures, id: \.self) { gesture in
                    row(gesture)
                }
            }
        }
    }

    private func row(_ gesture: GestureKind) -> some View {
        let isSelected = gesture == selected
        return HStack(spacing: 12) {
            IconTile(symbol: GestureInfo.symbol(gesture), highlighted: isSelected, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(gesture.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.ink)
                    if !GestureInfo.enabled(gesture, model.settings.gestures) {
                        Text("Off")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(UI.ink2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.black.opacity(0.06), in: Capsule())
                    }
                }
                Text(GestureInfo.hint(gesture)).font(UI.caption).foregroundStyle(UI.ink2).lineLimit(1)
            }
            Spacer(minLength: 10)
            ActionPicker(model: model, gesture: gesture).frame(width: 128)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isSelected ? UI.well : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(isSelected ? UI.hairline : .clear, lineWidth: 0.75))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selected = gesture } }
    }
}

/// Copy and glyphs for each gesture.
enum GestureInfo {
    static func symbol(_ g: GestureKind) -> String {
        switch g {
        case .pinchTap: return "hand.pinch"
        case .flickOut: return "arrow.clockwise"
        case .flickIn: return "arrow.counterclockwise"
        case .handDoubleTap: return "hand.tap"
        case .dwell: return "timer"
        case .screenTap, .screenDoubleTap: return "applewatch"
        case .screenLongPress: return "applewatch.watchface"
        }
    }

    static func hint(_ g: GestureKind) -> String {
        switch g {
        case .pinchTap: return "Tap thumb and index finger together"
        case .flickOut: return "Twist the wrist outward and let it spring back"
        case .flickIn: return "Twist the wrist inward and let it spring back"
        case .handDoubleTap: return "Apple's double-pinch, while the watch display is awake"
        case .dwell: return "Keep the pointer still for a moment"
        case .screenTap: return "Tap the display. Two quick taps double-click."
        case .screenDoubleTap: return "Tap the display twice"
        case .screenLongPress: return "Press and hold the display"
        }
    }

    static func enabled(_ g: GestureKind, _ t: GestureTuning) -> Bool {
        switch g {
        case .pinchTap: return t.tapEnabled
        case .flickOut, .flickIn: return t.flickEnabled
        case .dwell: return t.dwellEnabled
        default: return true
        }
    }
}

/// Pop-up menu choosing what a gesture does.
private struct ActionPicker: View {
    @ObservedObject var model: AppModel
    var gesture: GestureKind

    var body: some View {
        Picker("", selection: Binding(get: { model.settings.action(for: gesture) },
                                      set: { model.settings.setAction($0, for: gesture) })) {
            ForEach(PointerAction.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}

// MARK: - Detail

private struct GestureDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry
    var gesture: GestureKind
    var openDojo: () -> Void

    var body: some View {
        Surface(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                GestureIllustration(gesture: gesture)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(UI.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UI.hairline, lineWidth: 0.75))

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gesture.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(UI.ink)
                        Text(GestureInfo.hint(gesture) + ".").font(UI.caption).foregroundStyle(UI.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    ActionPicker(model: model, gesture: gesture).frame(width: 118)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    Rectangle().fill(UI.hairline).frame(height: 1)
                    tuning
                }
                .padding(.horizontal, 4)
            }
        }
        .animation(.easeOut(duration: 0.15), value: gesture)
    }

    @ViewBuilder
    private var tuning: some View {
        switch gesture {
        case .pinchTap:
            ToggleSetting(symbol: "hand.pinch", title: "Recognise finger taps", isOn: $model.settings.gestures.tapEnabled)
            SliderSetting(symbol: "gauge.with.dots.needle.33percent", title: "Tap strength needed",
                          value: $model.settings.gestures.tapThreshold, range: 0.06...0.5) { String(format: "%.2f g", $0) }
            SliderSetting(symbol: "waveform.path", title: "Stand-out factor",
                          detail: "How far a tap must rise above surrounding movement",
                          value: $model.settings.gestures.tapQuietRatio, range: 2...6) { String(format: "%.1f×", $0) }
            tapMeter
            calibrationNote
        case .flickOut, .flickIn:
            ToggleSetting(symbol: "arrow.triangle.2.circlepath", title: "Recognise wrist flicks", isOn: $model.settings.gestures.flickEnabled)
            SliderSetting(symbol: "speedometer", title: "Flick speed needed",
                          detail: "A flick is a quick twist that springs straight back",
                          value: $model.settings.gestures.flickRate, range: 3...9) { String(format: "%.1f rad/s", $0) }
            twistMeter
        case .dwell:
            ToggleSetting(symbol: "timer", title: "Act when the pointer is held still", isOn: $model.settings.gestures.dwellEnabled)
            SliderSetting(symbol: "hourglass", title: "Hold time",
                          value: $model.settings.gestures.dwellTime, range: 0.4...2.0, showsDivider: false) { String(format: "%.1f s", $0) }
        case .handDoubleTap:
            note("watchOS recognises Double Tap itself while the watch display is awake; Flare only decides what it does.")
        case .screenTap, .screenDoubleTap:
            note("Tap anywhere on the Flare screen of your watch. Two quick taps always double-click.")
        case .screenLongPress:
            note("Press and hold the Flare screen of your watch for about half a second.")
        }
    }

    private var tapMeter: some View {
        let threshold = model.settings.gestures.tapThreshold
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Live tap energy").font(UI.caption).foregroundStyle(UI.ink2)
                Spacer()
                HStack(spacing: 5) {
                    DashSwatch()
                    Text("Clicks above this line").font(UI.small).foregroundStyle(UI.ink2)
                }
            }
            LineChart(values: telemetry.tapHistory, ceiling: max(0.4, threshold * 2.2), color: UI.ink, threshold: threshold)
                .frame(height: 70)
            HStack(spacing: 5) {
                Circle().fill(telemetry.snapshot.streaming ? UI.green : UI.ink3).frame(width: 6, height: 6)
                Text(telemetry.snapshot.streaming ? "Peaks above the line click · ordinary arm movement is ignored"
                                                  : "Connect your watch to see your taps live")
                    .font(UI.small)
                    .foregroundStyle(telemetry.snapshot.streaming ? Color(hex: 0x1E7B39) : UI.ink2)
            }
        }
        .padding(.vertical, 12)
    }

    private var twistMeter: some View {
        let rate = abs(telemetry.snapshot.rates.z)
        let needed = model.settings.gestures.flickRate
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Live twist speed").font(UI.caption).foregroundStyle(UI.ink2)
                Spacer()
                Text(String(format: "%.1f / %.1f rad/s", telemetry.snapshot.streaming ? rate : 0, needed))
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(UI.ink)
            }
            MeterBar(value: telemetry.snapshot.streaming ? rate : 0, marker: needed, ceiling: needed * 1.6)
        }
        .padding(.vertical, 12)
    }

    private var calibrationNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(UI.ink2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Dojo calibration sets the strength from your own taps. Raise it if you get clicks you didn't make; lower it if taps are missed.")
                    .font(UI.caption).foregroundStyle(UI.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                LinkButton(title: "Calibrate in Dojo", action: openDojo)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UI.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UI.hairline, lineWidth: 0.75))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(UI.caption).foregroundStyle(UI.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A simple picture of the gesture: two fingers for taps, a turning watch for flicks.
private struct GestureIllustration: View {
    var gesture: GestureKind

    var body: some View {
        switch gesture {
        case .pinchTap, .handDoubleTap:
            ZStack {
                ZStack {
                    finger.offset(x: -54, y: 26)
                    finger.offset(x: 54, y: -26)
                }
                .rotationEffect(.degrees(-26))
                Circle()
                    .strokeBorder(UI.flare.opacity(0.55), lineWidth: 2)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(UI.flare.opacity(0.10)))
                if gesture == .handDoubleTap {
                    Text("×2").font(.system(size: 13, weight: .bold)).foregroundStyle(UI.ember).offset(x: 40, y: 34)
                }
            }
        case .flickOut, .flickIn:
            ZStack {
                WatchIllustration(width: 44) {
                    FlareMark().fill(UI.flare).frame(width: 24, height: 24 / FlareMark.aspect)
                }
                Image(systemName: gesture == .flickOut ? "arrow.clockwise" : "arrow.counterclockwise")
                    .font(.system(size: 64, weight: .ultraLight))
                    .foregroundStyle(UI.flare)
            }
        case .dwell:
            ZStack {
                Circle().stroke(Color.black.opacity(0.07), lineWidth: 6).frame(width: 74, height: 74)
                Circle().trim(from: 0, to: 0.7)
                    .stroke(UI.flare, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 74, height: 74)
                Image(systemName: "cursorarrow").font(.system(size: 22, weight: .semibold)).foregroundStyle(UI.ink)
            }
        case .screenTap, .screenDoubleTap, .screenLongPress:
            WatchIllustration(width: 60) {
                ZStack {
                    Circle().fill(UI.flare.opacity(0.35)).frame(width: 30, height: 30)
                    Circle().fill(UI.flare).frame(width: 14, height: 14)
                }
            }
        }
    }

    private var finger: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(hex: 0x3A3A3E), Color(hex: 0x1C1C1E)], startPoint: .top, endPoint: .bottom))
            .frame(width: 112, height: 26)
    }
}
