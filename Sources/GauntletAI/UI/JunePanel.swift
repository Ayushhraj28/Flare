import AppKit
import SwiftUI
import Combine

// MARK: - Model

/// Everything the June window shows. Updated by `AssistantController` on the main thread.
@MainActor
public final class JunePanelModel: ObservableObject {
    public enum Phase: Equatable { case listening, thinking, answering, done, notice, error }

    @Published public var phase: Phase = .done
    /// What June heard the user say.
    @Published public var heard = ""
    @Published public var answer = ""
    /// One line: "Reading your selection in Safari", "Searching the web…", "Looking at your screen".
    @Published public var status = ""
    @Published public var detail: String?
    @Published public var sources: [String] = []
    /// Microphone level 0...1 while listening.
    @Published public var level: Double = 0
    @Published public var speaking = false
    @Published public var hint = ""
    /// The last file action can be undone from the window.
    @Published public var canUndo = false

    var onStop: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSettings: (() -> Void)?
    var onClose: (() -> Void)?
    var onUndo: (() -> Void)?

    public init() {}
}

// MARK: - Window

/// The small floating June window. It never takes keyboard focus from the app you're working in,
/// so you can keep typing while June answers.
@MainActor
final class JunePanelController {
    let model = JunePanelModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<JunePanelView>?
    private var hideWork: DispatchWorkItem?
    private var resizeScheduled = false
    private var anchorTop: CGFloat?
    private var cancellable: AnyCancellable?
    private var position = PanelPosition.nearCursor
    private(set) var isVisible = false

    init() {
        cancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.fitToContent() }
        }
    }

    func show(position: PanelPosition, at cursor: CGPoint) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        if !isVisible {
            self.position = position
            place(panel, near: cursor)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
            isVisible = true
        }
        fitToContent()
    }

    func hide(after seconds: Double? = nil) {
        hideWork?.cancel()
        guard let seconds else { performHide(); return }
        guard seconds > 0 else { return }               // 0 = stay until closed
        let work = DispatchWorkItem { [weak self] in self?.performHide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func performHide() {
        guard let panel, isVisible else { return }
        isVisible = false
        anchorTop = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if !self.isVisible { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = JuneWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let hosting = NSHostingView(rootView: JunePanelView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel, near cursor: CGPoint) {
        // AppKit screens use bottom-left origin; the cursor comes in top-left (CG) coordinates.
        guard let primary = NSScreen.screens.first else { return }
        let flipped = CGPoint(x: cursor.x, y: primary.frame.maxY - cursor.y)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(flipped) }) ?? NSScreen.main ?? primary
        let visible = screen.visibleFrame
        let size = panel.frame.size
        var origin: CGPoint
        switch position {
        case .nearCursor:
            origin = CGPoint(x: flipped.x + 24, y: flipped.y - size.height - 24)
            if origin.x + size.width > visible.maxX - 12 { origin.x = flipped.x - size.width - 24 }
            if origin.y < visible.minY + 12 { origin.y = flipped.y + 24 }
        case .topRight:
            origin = CGPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        case .topCenter:
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16)
        }
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
        anchorTop = origin.y + size.height
    }

    /// Grows or shrinks the window to fit, keeping its top edge where it is.
    private func fitToContent() {
        guard let panel, let hosting, isVisible else { return }
        let fitting = hosting.fittingSize
        let height = min(max(fitting.height, 80), 520)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let top = anchorTop ?? panel.frame.maxY
        var frame = panel.frame
        frame.size = CGSize(width: 400, height: height)
        frame.origin.y = top - height
        if let screen = panel.screen, frame.minY < screen.visibleFrame.minY + 8 {
            frame.origin.y = screen.visibleFrame.minY + 8
        }
        panel.setFrame(frame, display: true, animate: false)
    }
}

/// Never becomes the key window, so clicks on June's buttons don't steal focus from your app.
private final class JuneWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Views

struct JunePanelView: View {
    @ObservedObject var model: JunePanelModel

    private var listening: Bool { model.phase == .listening }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !model.heard.isEmpty {
                Text("“\(model.heard)”")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.answer.isEmpty {
                ScrollView {
                    Text(model.answer)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 300)
            }
            if let detail = model.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(JuneColors.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.sources.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                    Text(model.sources.prefix(3).joined(separator: "  ·  ")).lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if !model.hint.isEmpty {
                Text(model.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(listening ? AnyShapeStyle(JuneColors.ring) : AnyShapeStyle(Color.black.opacity(0.10)),
                              lineWidth: listening ? 2 : 0.75)
        )
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 12) {
            JuneOrb(phase: model.phase, level: model.level, speaking: model.speaking)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("June").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(model.status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.phase == .thinking || model.phase == .answering || model.speaking || model.phase == .listening {
                PanelButton(symbol: "stop.fill", help: "Stop") { model.onStop?() }
            }
            if model.canUndo {
                PanelButton(symbol: "arrow.uturn.backward", help: "Undo") { model.onUndo?() }
            }
            if !model.answer.isEmpty {
                PanelButton(symbol: "doc.on.doc", help: "Copy the answer") { model.onCopy?() }
            }
            PanelButton(symbol: "gearshape", help: "June settings") { model.onSettings?() }
            PanelButton(symbol: "xmark", help: "Close") { model.onClose?() }
        }
    }
}

private struct PanelButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(Color(red: 0.37, green: 0.37, blue: 0.40))
                .background(Color.black.opacity(0.055), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Flare's warm palette for June.
enum JuneColors {
    static let flare = Color(red: 1.0, green: 0.478, blue: 0.188)       // #FF7A30
    static let glow = Color(red: 1.0, green: 0.588, blue: 0.345)        // #FF9658
    static let gold = Color(red: 1.0, green: 0.725, blue: 0.40)         // #FFB966
    static let ember = Color(red: 0.761, green: 0.345, blue: 0.122)     // #C2581F
    static let ring = AngularGradient(colors: [flare, gold, ember, flare], center: .center)
}

/// June's orb: breathes with your voice while listening, spins while thinking, ripples while speaking.
struct JuneOrb: View {
    let phase: JunePanelModel.Phase
    let level: Double
    let speaking: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse: Double = {
                switch phase {
                case .listening: return 1 + min(level, 1) * 0.35 + sin(t * 3) * 0.03
                case .thinking: return 1 + sin(t * 4) * 0.06
                default: return speaking ? 1 + abs(sin(t * 7)) * 0.12 : 1
                }
            }()
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [JuneColors.flare, JuneColors.gold, JuneColors.ember, JuneColors.flare],
                                          center: .center, angle: .degrees(phase == .thinking ? t * 220 : t * 40)))
                    .blur(radius: 1.5)
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0)],
                                         center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 14))
                if phase == .error {
                    Image(systemName: "exclamationmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                }
            }
            .scaleEffect(pulse)
            .shadow(color: JuneColors.flare.opacity(phase == .listening ? 0.7 : 0.35), radius: phase == .listening ? 10 : 5)
        }
    }
}
