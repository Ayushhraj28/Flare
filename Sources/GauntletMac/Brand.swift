import AppKit
import SwiftUI

// MARK: - Flare brand

/// The Flare mark (watch, orbit and arrow), traced from the brand artwork used on
/// flare-watch-mouse.web.app. Drawn as a shape so it stays crisp at any size and can be
/// filled with titanium, Flare orange or plain ink.
struct FlareMark: Shape {
    func path(in rect: CGRect) -> Path {
        let box = CGRect(x: 277, y: 48, width: 786, height: 416)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.midX - box.midX * scale
        let dy = rect.midY - box.midY * scale
        var path = Path()
        for outline in [FlareMarkData.orbit, FlareMarkData.watchAndArrow, FlareMarkData.crown] {
            var points: [CGPoint] = []
            points.reserveCapacity(outline.count / 2)
            var i = 0
            while i + 1 < outline.count {
                points.append(CGPoint(x: outline[i] * scale + dx, y: outline[i + 1] * scale + dy))
                i += 2
            }
            path.addLines(points)
            path.closeSubpath()
        }
        return path
    }

    /// Width / height of the artwork.
    static let aspect: CGFloat = 786.0 / 416.0
}

private enum FlareMarkData {
    static let orbit: [CGFloat] = [
        480,165, 481,166, 481,168, 475,184, 470,204, 466,226, 466,230, 465,236, 464,237, 453,240, 440,248, 417,264, 408,272, 402,273,
        400,274, 395,280, 395,285, 391,291, 390,296, 375,315, 359,341, 347,366, 336,397, 329,425, 325,461, 322,462, 303,462, 298,464,
        292,462, 288,462, 282,464, 279,464, 277,461, 277,455, 280,427, 284,402, 288,395, 288,386, 293,367, 300,347, 306,340, 307,331,
        314,317, 333,285, 349,264, 361,249, 381,229, 397,215, 413,203, 440,184, 459,173, 473,166,
    ]
    static let watchAndArrow: [CGFloat] = [
        485,207, 491,184, 504,156, 513,142, 514,138, 520,130, 533,118, 546,101, 553,84, 557,80, 560,67, 560,61, 562,57, 567,53,
        572,51, 582,50, 594,50, 599,49, 610,49, 615,48, 667,48, 672,49, 685,49, 690,50, 702,50, 709,51, 713,51, 720,56,
        726,64, 731,85, 737,99, 747,113, 761,127, 771,140, 785,161, 785,164, 781,172, 778,186, 778,204, 781,218, 785,227, 789,232,
        794,235, 804,237, 805,240, 805,253, 803,268, 801,280, 796,297, 789,313, 783,324, 777,334, 770,343, 746,355, 740,357, 734,357,
        727,359, 721,362, 714,361, 697,364, 667,364, 648,362, 645,359, 645,358, 647,357, 657,357, 670,354, 679,352, 690,348, 704,341,
        722,328, 735,314, 745,299, 753,282, 758,265, 760,253, 760,229, 759,222, 755,205, 750,191, 746,183, 732,162, 719,149, 707,140,
        690,131, 676,126, 660,122, 653,121, 629,121, 606,126, 590,132, 578,138, 563,149, 551,161, 542,173, 531,195, 526,214, 523,229,
        523,248, 524,256, 529,276, 535,292, 541,303, 552,318, 561,327, 563,330, 572,339, 585,349, 605,361, 630,371, 650,376, 665,379,
        674,379, 679,380, 687,379, 698,379, 723,374, 743,369, 773,356, 788,348, 807,337, 827,323, 843,311, 871,289, 889,271, 894,268,
        924,238, 929,232, 929,229, 927,226, 921,225, 918,220, 913,217, 890,206, 889,204, 890,201, 1040,147, 1058,139, 1062,139, 1063,141,
        1059,158, 1038,227, 1012,319, 1009,320, 1008,318, 985,279, 983,276, 981,275, 947,310, 942,313, 926,329, 922,331, 917,337, 908,341,
        904,346, 901,347, 865,375, 835,394, 821,402, 799,413, 777,422, 744,432, 719,436, 702,437, 697,438, 670,437, 654,435, 630,430,
        613,424, 589,413, 564,396, 553,388, 531,366, 518,350, 505,329, 492,301, 485,275, 482,250, 482,231,
    ]
    static let crown: [CGFloat] = [
        795,165, 810,165, 815,168, 817,172, 818,178, 818,215, 817,218, 798,218, 794,217, 792,214, 792,209, 790,203, 787,200, 787,198,
        787,185, 788,173, 791,168,
    ]
}

/// Brushed-titanium fill, as on the website logo.
enum Titanium {
    static let gradient = LinearGradient(colors: [Color(hex: 0xF1F3F5), Color(hex: 0x8C949E)],
                                         startPoint: .top, endPoint: .bottom)
}

/// The app icon in miniature: titanium mark on a dark plate with a warm glow.
struct FlareAppTile: View {
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x2E343D), Color(hex: 0x16191E)], startPoint: .top, endPoint: .bottom))
            .overlay(
                RadialGradient(colors: [UI.flare.opacity(0.30), .clear], center: UnitPoint(x: 0.85, y: 0.95),
                               startRadius: 0, endRadius: size * 0.7)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)))
            .overlay(
                FlareMark().fill(Titanium.gradient)
                    .frame(width: size * 0.72, height: size * 0.72 / FlareMark.aspect)
                    .shadow(color: .black.opacity(0.45), radius: size * 0.03, y: size * 0.02))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
    }
}

/// "FLARE" set wide, echoing the wordmark.
struct FlareWordmark: View {
    var size: CGFloat = 16
    var color: Color = UI.ink

    var body: some View {
        Text("Flare")
            .font(.system(size: size, weight: .bold))
            .fontWidth(.expanded)
            .tracking(-0.2)
            .foregroundStyle(color)
    }
}

extension Color {
    /// `Color(hex: 0xFF7A30)`
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
