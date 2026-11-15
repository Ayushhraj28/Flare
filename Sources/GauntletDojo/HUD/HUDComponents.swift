import SwiftUI

/// Text on a Flare-orange fill.
let flareInk = Color(red: 0.09, green: 0.04, blue: 0.01)

/// A white card, as on every Flare page.
struct HUDPanel<Content: View>: View {
    var title: String?
    var symbol: String?
    var tint = DojoTheme.textPrimary
    var badge: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let title {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(DojoTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.05)))
                    }
                }
            }
            content
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DojoTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DojoTheme.panelStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 10, y: 3)
    }
}

/// Small rounded status label.
struct Chip: View {
    var text: String
    var symbol: String?
    var tone: Color
    var filled = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            if !text.isEmpty { Text(text).font(.system(size: 11, weight: .semibold)) }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(filled ? flareInk : tone)
        .background(Capsule().fill(filled ? tone.opacity(0.9) : tone.opacity(0.12)))
    }
}

/// Capsule button: orange when prominent, grey otherwise.
struct HUDButtonStyle: ButtonStyle {
    var tone = DojoTheme.accent
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(prominent ? flareInk : (tone == DojoTheme.accent ? DojoTheme.textPrimary : tone))
            .background(Capsule().fill(prominent ? tone : Color.black.opacity(configuration.isPressed ? 0.10 : 0.055)))
            .overlay(Capsule().strokeBorder(prominent ? Color.black.opacity(0.08) : Color.black.opacity(0.07), lineWidth: 0.75))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
    }
}

/// Round icon button for the header.
struct IconButtonStyle: ButtonStyle {
    var active = false
    var tone = DojoTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 30, height: 30)
            .foregroundStyle(active ? DojoTheme.secondary : DojoTheme.textSecondary)
            .background(Circle().fill(active ? tone.opacity(0.14) : Color.black.opacity(configuration.isPressed ? 0.10 : 0.055)))
            .overlay(Circle().strokeBorder(active ? tone.opacity(0.35) : Color.black.opacity(0.07), lineWidth: 0.75))
            .contentShape(Circle())
    }
}

struct ProgressLine: View {
    var value: Double
    var tone = DojoTheme.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.07))
                Capsule().fill(tone).frame(width: max(6, proxy.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: 6)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + lineHeight)
    }
}

/// A keyboard / mouse key and what it does.
struct KeyHint: View {
    var key: String
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 19)
                .foregroundStyle(DojoTheme.textPrimary)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.black.opacity(0.14), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.06), radius: 0, y: 1)
            if !label.isEmpty {
                Text(label).font(.system(size: 11)).foregroundStyle(DojoTheme.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}
