import AppKit
import SwiftUI
import GauntletDojo

// MARK: - Design tokens

/// Flare's light theme: paper background, white cards, ink text and one warm accent.
/// The palette is shared with the Flare website (flare-watch-mouse.web.app).
enum UI {
    // Brand
    static let flare = Color(hex: 0xFF7A30)
    static let flareHi = Color(hex: 0xFF9658)
    /// Darker orange for text and strokes on light tints.
    static let ember = Color(hex: 0xC2581F)
    /// Text on a Flare-orange fill.
    static let flareInk = Color(hex: 0x170A02)
    static let flareTint = Color(hex: 0xFF7A30, opacity: 0.12)

    // Surfaces
    static let paper = Color(hex: 0xF2F2F5)
    static let card = Color.white
    /// Inset fills inside cards: stat boxes, charts, fields.
    static let well = Color(hex: 0xF6F6F8)
    static let line = Color.black.opacity(0.08)
    static let hairline = Color.black.opacity(0.06)

    // Text
    static let ink = Color(hex: 0x1D1D1F)
    static let ink2 = Color(hex: 0x5E5E66)
    static let ink3 = Color(hex: 0x9A9AA2)

    // Status
    static let green = Color(hex: 0x2FA84F)
    static let amber = Color(hex: 0xE59A1F)
    static let red = Color(hex: 0xE5484D)
    static let blue = Color(hex: 0x5B8DEF)

    /// Kept for code that still asks for "the accent".
    static let accent = flare

    static let cardRadius: CGFloat = 16
    static let pagePadding: CGFloat = 28
    static let spacing: CGFloat = 16

    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold) }
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let headline = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11.5)
    static let small = Font.system(size: 10.5, weight: .medium)
}

// MARK: - Window chrome

/// Native macOS vibrancy, which SwiftUI materials alone cannot give a whole window.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blending
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// The page background: paper with a faint warm glow in the top corner.
struct Backdrop: View {
    var glow: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let reach = max(proxy.size.width, proxy.size.height)
            ZStack {
                UI.paper
                RadialGradient(colors: [UI.flare.opacity(0.07 * glow), .clear],
                               center: UnitPoint(x: 0.92, y: 0.0), startRadius: 0, endRadius: reach * 0.55)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Surfaces

/// A white card with a hairline border and a soft shadow.
struct Surface<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = UI.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(UI.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(UI.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.035), radius: 10, y: 3)
    }
}

/// A titled card: title (and optional subtitle) on the left, an optional control on the right.
struct Panel<Content: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    var padding: CGFloat
    var trailing: Trailing
    var content: Content

    init(_ title: String, subtitle: String? = nil, padding: CGFloat = 18,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.padding = padding
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        Surface(padding: padding) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(UI.cardTitle).foregroundStyle(UI.ink)
                        if let subtitle {
                            Text(subtitle).font(UI.caption).foregroundStyle(UI.ink2)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                content
            }
        }
    }
}

extension Panel where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, padding: padding, trailing: { EmptyView() }, content: content)
    }
}

/// Small rounded tile holding a row's glyph. `highlighted` tints it Flare orange.
struct IconTile: View {
    var symbol: String
    var highlighted = false
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(highlighted ? UI.flareTint : UI.well)
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(highlighted ? UI.flare.opacity(0.25) : UI.hairline, lineWidth: 0.75))
            .overlay(Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(highlighted ? UI.ember : UI.ink2))
            .frame(width: size, height: size)
    }
}

/// Status chip: "● Connected", "Engaged", "Flicks off", "Simulated".
struct StatusChip: View {
    enum Tone { case green, flare, neutral, amber, red }

    var text: String
    var tone: Tone = .neutral
    var dot = false
    var symbol: String?
    var spinning = false

    private var colors: (fg: Color, bg: Color, dot: Color) {
        switch tone {
        case .green: return (Color(hex: 0x1E7B39), Color(hex: 0x2FA84F, opacity: 0.12), UI.green)
        case .flare: return (UI.ember, UI.flareTint, UI.flare)
        case .neutral: return (UI.ink2, Color.black.opacity(0.05), UI.ink3)
        case .amber: return (Color(hex: 0x9A6206), UI.amber.opacity(0.14), UI.amber)
        case .red: return (Color(hex: 0xB42328), UI.red.opacity(0.12), UI.red)
        }
    }

    var body: some View {
        let c = colors
        HStack(spacing: 5) {
            if spinning {
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 10, height: 10)
            } else if dot {
                Circle().fill(c.dot).frame(width: 6, height: 6)
            }
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(c.fg)
        .background(c.bg, in: Capsule())
    }
}

/// Labelled figure in a grey box: "Battery 82%".
struct StatBox: View {
    var label: String
    var value: String
    var tint: Color = UI.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(UI.small).foregroundStyle(UI.ink2)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(UI.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UI.hairline, lineWidth: 0.75))
    }
}

/// Keyboard key cap used in hints: [Space] lower / raise.
struct KeyCap: View {
    var key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(UI.ink)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 19)
            .background(.white, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.black.opacity(0.14), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.06), radius: 0, y: 1)
    }
}

/// Orange-tinted message strip with an optional action: "One step left: add your Gemini API key".
struct Banner: View {
    var symbol: String
    var title: String
    var text: String
    var tone: StatusChip.Tone = .flare
    var action: String?
    var perform: () -> Void = {}

    private var tint: Color {
        switch tone {
        case .amber: return UI.amber
        case .red: return UI.red
        case .green: return UI.green
        default: return UI.flare
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.7))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.75))
                .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint == UI.flare ? UI.ember : tint))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.ink)
                Text(text).font(UI.caption).foregroundStyle(UI.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let action {
                Button(action, action: perform).buttonStyle(FlareButtonStyle(kind: .primary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            LinearGradient(colors: [tint.opacity(0.13), tint.opacity(0.06)], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }
}

// MARK: - Rows

/// One setting: glyph tile, title and optional detail on the left, a control on the right.
struct SettingRow<Accessory: View>: View {
    var symbol: String
    var title: String
    var detail: String?
    var badge: String?
    var showsDivider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(UI.ink)
                        if let badge { StatusChip(text: badge).scaleEffect(0.9, anchor: .leading) }
                    }
                    if let detail {
                        Text(detail).font(UI.caption).foregroundStyle(UI.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.vertical, 10)
            if showsDivider {
                Rectangle().fill(UI.hairline).frame(height: 1)
            }
        }
    }
}

struct ToggleSetting: View {
    var symbol: String
    var title: String
    var detail: String?
    @Binding var isOn: Bool
    var showsDivider = true

    var body: some View {
        SettingRow(symbol: symbol, title: title, detail: detail, showsDivider: showsDivider) {
            FlareSwitch(isOn: $isOn)
        }
    }
}

/// A setting whose control is a slider: label and value on one line, the slider underneath.
struct SliderSetting: View {
    var symbol: String
    var title: String
    var detail: String?
    @Binding var value: Double
    var range: ClosedRange<Double>
    var showsDivider = true
    var format: (Double) -> String

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 12) {
                    IconTile(symbol: symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(UI.ink)
                        if let detail {
                            Text(detail).font(UI.caption).foregroundStyle(UI.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(format(value))
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(UI.ink)
                }
                FlareSlider(value: $value, range: range)
            }
            .padding(.vertical, 10)
            if showsDivider {
                Rectangle().fill(UI.hairline).frame(height: 1)
            }
        }
    }
}

// MARK: - Controls

/// Flare's switch: a native macOS switch in Flare orange.
struct FlareSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(UI.flare)
    }
}

/// Thin track, orange fill, white knob.
struct FlareSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color = UI.flare

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 16
            let travel = max(1, proxy.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.08)).frame(height: 4)
                Capsule().fill(tint).frame(width: fraction * travel + knob / 2, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .offset(x: fraction * travel)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let t = Double(min(1, max(0, (drag.location.x - knob / 2) / travel)))
                value = range.lowerBound + t * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

/// Grey track with a white raised segment, as in System Settings.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var disabled = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? UI.ink : UI.ink2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.white)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(UI.hairline, lineWidth: 0.5))
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// Text field on a light grey well.
struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(UI.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(UI.line, lineWidth: 0.75))
    }
}

extension View {
    func flareField() -> some View { modifier(FieldStyle()) }
}

// MARK: - Buttons

/// Capsule buttons. `.primary` is the one Flare-orange action in a view; `.secondary` is grey.
struct FlareButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, plain }
    var kind: Kind = .secondary
    var compact = false
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        FlareButton(configuration: configuration, style: self)
    }

    /// Reads the environment so disabled buttons look disabled.
    private struct FlareButton: View {
        let configuration: Configuration
        let style: FlareButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            style.render(configuration).opacity(isEnabled ? 1 : 0.45)
        }
    }

    fileprivate func render(_ configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: compact ? 12 : 12.5, weight: .semibold))
            .labelStyle(TightLabelStyle())
            .lineLimit(1)
            .padding(.horizontal, compact ? 11 : 14)
            .frame(height: compact ? 26 : 30)
            .frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(foreground)
            .background(background(pressed), in: Capsule())
            .overlay(Capsule().strokeBorder(border, lineWidth: 0.75))
            .shadow(color: kind == .primary ? UI.flare.opacity(pressed ? 0.15 : 0.30) : .clear, radius: 6, y: 2)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return UI.flareInk
        case .secondary: return UI.ink
        case .destructive: return UI.red
        case .plain: return UI.ember
        }
    }

    private func background(_ pressed: Bool) -> AnyShapeStyle {
        switch kind {
        case .primary:
            return AnyShapeStyle(LinearGradient(colors: pressed ? [UI.flare, UI.ember] : [UI.flareHi, UI.flare],
                                                startPoint: .top, endPoint: .bottom))
        case .secondary, .destructive:
            return AnyShapeStyle(Color.black.opacity(pressed ? 0.10 : 0.055))
        case .plain:
            return AnyShapeStyle(Color.clear)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return UI.ember.opacity(0.25)
        case .secondary, .destructive: return Color.black.opacity(0.07)
        case .plain: return .clear
        }
    }
}

/// Icon and title closer together than the default label.
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}

/// Round grey icon button (Dojo stats, help).
struct CircleIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? UI.ember : UI.ink2)
            .frame(width: 30, height: 30)
            .background(active ? UI.flareTint : Color.black.opacity(configuration.isPressed ? 0.10 : 0.055), in: Circle())
            .overlay(Circle().strokeBorder(active ? UI.flare.opacity(0.3) : Color.black.opacity(0.07), lineWidth: 0.75))
    }
}

/// Orange text link with an arrow: "Edit in Gestures →".
struct LinkButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(UI.ember)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Page header

/// Large title with a one-line description and optional trailing controls.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(UI.title()).foregroundStyle(UI.ink)
                Text(subtitle).font(UI.body).foregroundStyle(UI.ink2)
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.top, 40)
        .padding(.bottom, 4)
    }
}

// MARK: - Watch illustration

/// A dark Apple Watch with whatever the screen should show.
struct WatchIllustration<Screen: View>: View {
    var width: CGFloat = 72
    @ViewBuilder var screen: Screen

    var body: some View {
        let height = width * 1.22
        ZStack {
            // Band stubs.
            VStack(spacing: 0) {
                band.frame(height: height * 0.22)
                Spacer()
                band.frame(height: height * 0.22)
            }
            .frame(width: width * 0.66, height: height * 1.38)
            // Case.
            RoundedRectangle(cornerRadius: width * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x3A3A3E), Color(hex: 0x1C1C1E)], startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: height)
                .overlay(RoundedRectangle(cornerRadius: width * 0.27, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            // Screen.
            RoundedRectangle(cornerRadius: width * 0.21, style: .continuous)
                .fill(Color.black)
                .frame(width: width * 0.84, height: height * 0.86)
                .overlay(screen.frame(width: width * 0.84, height: height * 0.86))
                .clipShape(RoundedRectangle(cornerRadius: width * 0.21, style: .continuous))
            // Crown and button.
            Capsule()
                .fill(LinearGradient(colors: [Color(hex: 0x4A4A4F), Color(hex: 0x232326)], startPoint: .leading, endPoint: .trailing))
                .frame(width: width * 0.07, height: height * 0.18)
                .offset(x: width * 0.52, y: -height * 0.12)
            Capsule()
                .fill(Color(hex: 0x2A2A2D))
                .frame(width: width * 0.045, height: height * 0.16)
                .offset(x: width * 0.51, y: height * 0.14)
        }
        .frame(width: width * 1.1, height: height * 1.38)
    }

    private var band: some View {
        RoundedRectangle(cornerRadius: width * 0.1, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x2C2C2F), Color(hex: 0x3A3A3E)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Charts

/// Rolling line chart on a light well, with an optional dashed threshold and dots on the peaks above it.
struct LineChart: View {
    var values: [Double]
    var ceiling: Double
    var color: Color = UI.ink
    var threshold: Double?
    var fill = false
    var lineWidth: CGFloat = 1.4

    var body: some View {
        Canvas { context, size in
            // Grid.
            for i in 1..<4 {
                let y = size.height * CGFloat(i) / 4
                var g = Path()
                g.move(to: CGPoint(x: 0, y: y))
                g.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(g, with: .color(Color.black.opacity(0.05)), lineWidth: 1)
            }
            guard values.count > 1, ceiling > 0 else { return }
            let step = size.width / CGFloat(values.count - 1)
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(1, max(0, v / ceiling))) * (size.height - 8) - 4 }
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: y(v))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            if fill {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.18), color.opacity(0)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
            if let threshold {
                var m = Path()
                m.move(to: CGPoint(x: 0, y: y(threshold)))
                m.addLine(to: CGPoint(x: size.width, y: y(threshold)))
                context.stroke(m, with: .color(UI.flare), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                // Peaks above the line.
                if values.count > 2 {
                    for i in 1..<(values.count - 1) where values[i] > threshold && values[i] >= values[i - 1] && values[i] > values[i + 1] {
                        let p = CGPoint(x: CGFloat(i) * step, y: y(values[i]))
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(UI.flare))
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .background(UI.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UI.hairline, lineWidth: 0.75))
    }
}

/// Small dashed line used as a legend swatch.
struct DashSwatch: View {
    var color: Color = UI.flare

    var body: some View {
        Canvas { context, size in
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        }
        .frame(width: 14, height: 6)
    }
}

// MARK: - Gauges

/// Elevation of the forearm on a vertical half-dial: the zone above the engage angle is warm,
/// the part between that angle and the arm is solid orange.
struct ElevationDial: View {
    var degrees: Double
    var threshold: Double?
    var engaged: Bool
    var valid: Bool

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width * 0.66, size.height * 0.40)
            let center = CGPoint(x: size.width * 0.12, y: size.height / 2)
            func point(_ deg: Double, _ r: CGFloat) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: center.x + CGFloat(cos(a)) * r, y: center.y - CGFloat(sin(a)) * r)
            }
            func arc(_ from: Double, _ to: Double, _ r: CGFloat) -> Path {
                var p = Path()
                p.addArc(center: center, radius: r, startAngle: .degrees(-from), endAngle: .degrees(-to), clockwise: true)
                return p
            }
            let band: CGFloat = 12
            let r = radius - band / 2
            let t = threshold ?? -90
            context.stroke(arc(-90, t, r), with: .color(Color.black.opacity(0.07)), lineWidth: band)
            context.stroke(arc(t, 90, r), with: .color(UI.flare.opacity(0.16)), lineWidth: band)
            if valid, degrees > t {
                context.stroke(arc(t, min(90, degrees), r), with: .color(UI.flare.opacity(engaged ? 1 : 0.55)), lineWidth: band)
            }
            // Ticks outside the band.
            for d in stride(from: -90.0, through: 90.0, by: 15.0) {
                var tick = Path()
                tick.move(to: point(d, radius + 3))
                tick.addLine(to: point(d, radius + (d.truncatingRemainder(dividingBy: 45) == 0 ? 9 : 6)))
                context.stroke(tick, with: .color(Color.black.opacity(0.22)), lineWidth: 1)
            }
            // Engage angle.
            if let threshold {
                var tick = Path()
                tick.move(to: point(threshold, radius - band - 2))
                tick.addLine(to: point(threshold, radius + 10))
                context.stroke(tick, with: .color(UI.ember), lineWidth: 1.5)
                context.draw(Text(String(format: "%.0f°", threshold)).font(.system(size: 9.5, weight: .semibold)).foregroundColor(UI.ember),
                             at: point(threshold, radius + 24))
            }
            context.draw(Text("90°").font(.system(size: 9.5)).foregroundColor(UI.ink3), at: point(90, radius + 14))
            context.draw(Text("0°").font(.system(size: 9.5)).foregroundColor(UI.ink3), at: point(0, radius + 20))
            context.draw(Text("−90°").font(.system(size: 9.5)).foregroundColor(UI.ink3), at: point(-90, radius + 14))
            // Needle.
            let shown = valid ? max(-90, min(90, degrees)) : 0
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: point(shown, r))
            context.stroke(needle, with: .color(valid ? UI.ink : UI.ink3), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let tip = point(shown, r)
            context.fill(Path(ellipseIn: CGRect(x: tip.x - 4, y: tip.y - 4, width: 8, height: 8)), with: .color(valid ? UI.ink : UI.ink3))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)), with: .color(.white))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)), with: .color(UI.flare), lineWidth: 2)
        }
    }
}

/// Wrist twist on a top half-dial with a level bar: In on the left, Out on the right.
struct TwistGauge: View {
    var degrees: Double
    var valid: Bool

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width / 2 - 8, size.height - 22)
            let center = CGPoint(x: size.width / 2, y: radius + 8)
            func point(_ deg: Double, _ r: CGFloat) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: center.x + CGFloat(cos(a)) * r, y: center.y - CGFloat(sin(a)) * r)
            }
            var band = Path()
            band.addArc(center: center, radius: radius - 7, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            context.stroke(band, with: .color(Color.black.opacity(0.06)), lineWidth: 14)
            for d in stride(from: 0.0, through: 180.0, by: 10.0) {
                var tick = Path()
                tick.move(to: point(d, radius - 2))
                tick.addLine(to: point(d, radius - (d.truncatingRemainder(dividingBy: 30) == 0 ? 12 : 8)))
                context.stroke(tick, with: .color(Color.black.opacity(0.25)), lineWidth: 1)
            }
            var zero = Path()
            zero.move(to: point(90, radius + 1))
            zero.addLine(to: point(90, radius - 14))
            context.stroke(zero, with: .color(UI.flare), lineWidth: 3)
            // Level bar, turned by the twist.
            let shown = valid ? max(-80, min(80, degrees)) : 0
            let a = -shown * .pi / 180
            let half = radius * 0.72
            let dx = CGFloat(cos(a)) * half, dy = CGFloat(sin(a)) * half
            var bar = Path()
            bar.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
            bar.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
            context.stroke(bar, with: .color(valid ? UI.ink : UI.ink3), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            var knob = context
            knob.translateBy(x: center.x, y: center.y)
            knob.rotate(by: .radians(a))
            knob.fill(Path(roundedRect: CGRect(x: -9, y: -6, width: 18, height: 12), cornerRadius: 3), with: .color(UI.flare))
            context.draw(Text("In").font(.system(size: 9.5)).foregroundColor(UI.ink2), at: CGPoint(x: center.x - radius, y: center.y + 12))
            context.draw(Text("Out").font(.system(size: 9.5)).foregroundColor(UI.ink2), at: CGPoint(x: center.x + radius, y: center.y + 12))
        }
    }
}

/// Thin progress bar with a marker: "Flick speed 0.8 / 5.0 rad/s".
struct MeterBar: View {
    var value: Double
    var marker: Double
    var ceiling: Double

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.07))
                Capsule().fill(UI.ink).frame(width: max(4, w * CGFloat(min(1, value / ceiling))))
                Rectangle().fill(UI.flare).frame(width: 2, height: 10)
                    .offset(x: w * CGFloat(min(1, marker / ceiling)) - 1)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 10)
    }
}
