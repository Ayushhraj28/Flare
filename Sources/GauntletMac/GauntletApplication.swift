import AppKit
import SceneKit
import SwiftUI
import GauntletEngine
import GauntletDojo

/// In this SDK `@State` resolves to a macro whose compiler plugin ships only with full Xcode.
/// Going through a typealias selects the plain property wrapper, which builds everywhere.
typealias LocalState = SwiftUI.State

enum Page: String, CaseIterable, Identifiable {
    case control, dojo, gestures, june, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: return "Control"
        case .dojo: return "Dojo"
        case .gestures: return "Gestures"
        case .june: return "June"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .control: return "scope"
        case .dojo: return "cube"
        case .gestures: return "hand.tap"
        case .june: return "waveform"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @LocalState private var page: Page

    init(model: AppModel, page: Page? = nil) {
        self.model = model
        _page = LocalState(initialValue: page ?? RootView.launchPage)
    }

    /// `--page dojo` opens straight onto a page (handy for demos and screenshots).
    private static var launchPage: Page {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--page"), args.indices.contains(flag + 1) else { return .control }
        return Page(rawValue: args[flag + 1]) ?? .control
    }

    var body: some View {
        ZStack {
            Backdrop(glow: page == .control || page == .june ? 1 : 0.6)
            HStack(spacing: 0) {
                Sidebar(model: model, telemetry: model.telemetry, page: $page)
                    .padding(8)
                ZStack {
                    switch page {
                    case .control: ControlPage(model: model, openDojo: { page = .dojo }, openGestures: { page = .gestures })
                    case .dojo: DojoPage(model: model)
                    case .gestures: GesturesPage(model: model, openDojo: { page = .dojo })
                    case .june: JunePage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.16), value: page)
            }
        }
        .ignoresSafeArea()
        .background(WindowChrome())
        .preferredColorScheme(.light)
        .tint(UI.flare)
        .onAppear { model.start() }
        .onReceive(model.$requestedPage.compactMap { $0 }) { name in
            if let target = Page(rawValue: name) { page = target }
            model.requestedPage = nil
        }
    }
}

/// Gives the hidden title bar a toolbar's height, so the traffic lights sit inside the floating
/// sidebar (as in macOS's own inset sidebars) instead of on its edge.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.styleMask.contains(.titled), window.toolbar == nil else { return }
            let toolbar = NSToolbar(identifier: "flare.window")
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
    }
}

/// The Dojo draws its own page (header, tabs, sandbox and panels).
private struct DojoPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DojoView(host: model.dojoHost)
    }
}

/// Floating glass sidebar: the app, the pages, and the watch at a glance.
private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                FlareAppTile(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    FlareWordmark(size: 15)
                    Text("Air mouse").font(.system(size: 11)).foregroundStyle(UI.ink2)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 46)
            .padding(.bottom, 18)

            ForEach(Page.allCases) { item in
                let selected = page == item
                Button { page = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? UI.flare : UI.ink2)
                            .frame(width: 20)
                        Text(item.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(UI.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(selected ? Color.black.opacity(0.075) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
            deviceCard
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                VisualEffect(material: .sidebar)
                Color.black.opacity(0.035)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var deviceCard: some View {
        let s = telemetry.snapshot
        let connected = model.isConnected
        let status: (text: String, tone: Color, searching: Bool) = {
            switch model.link {
            case .waiting: return ("Searching…", UI.ink3, true)
            case .handshaking: return ("Connecting…", UI.ink3, true)
            case .awaitingApproval: return ("Wants to pair", UI.amber, false)
            case .connected:
                if s.paused { return ("Paused", UI.amber, false) }
                if model.sandboxActive { return ("In the Dojo", UI.flare, false) }
                return ("Connected", UI.green, false)
            }
        }()
        let name: String = {
            switch model.link {
            case .connected(let name, _), .awaitingApproval(let name, _): return name
            default: return connected ? "Apple Watch" : "No watch"
            }
        }()
        return HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(connected ? UI.flareTint : Color.black.opacity(0.05))
                .overlay(Image(systemName: connected ? "applewatch" : "applewatch.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(connected ? UI.ember : UI.ink2))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(UI.ink)
                    .lineLimit(1).minimumScaleFactor(0.85)
                HStack(spacing: 4) {
                    if status.searching {
                        ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 9, height: 9)
                    } else {
                        Circle().fill(status.tone).frame(width: 5, height: 5)
                    }
                    Text(status.text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(UI.ink2).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if connected, let battery = s.battery {
                HStack(spacing: 3) {
                    Image(systemName: battery <= 15 ? "battery.25percent" : "battery.75percent")
                        .font(.system(size: 10))
                        .foregroundStyle(battery <= 15 ? UI.red : UI.ink3)
                    Text("\(battery)%").font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(UI.ink2)
                }
                .fixedSize()
            }
        }
        .padding(9)
        .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.75))
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Divider()
        Button(telemetry.snapshot.paused ? "Resume Control" : "Pause Control") { model.togglePause() }
            .keyboardShortcut("p")
        Button("Recenter") { model.recenter() }
        Divider()
        Button("Open Flare") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Flare") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusLine: String {
        switch model.link {
        case .connected(let name, _): return telemetry.snapshot.paused ? "\(name) — paused" : "\(name) — connected"
        case .awaitingApproval(let name, _): return "\(name) wants to pair"
        case .handshaking: return "Connecting…"
        case .waiting: return "Waiting for your watch"
        }
    }
}

/// The Flare mark as a template image for the menu bar (dimmed while no watch is connected).
@MainActor
private enum MenuBarIcon {
    static let connected = make(opacity: 1)
    static let idle = make(opacity: 0.5)

    private static func make(opacity: Double) -> NSImage {
        let width: CGFloat = 24
        let renderer = ImageRenderer(content:
            FlareMark().fill(Color.black.opacity(opacity))
                .frame(width: width, height: width / FlareMark.aspect)
                .padding(.vertical, 2))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "applewatch", accessibilityDescription: "Flare") ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = "Flare"
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare binary (swift run) rather than from the .app bundle: still behave like an app.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        scheduleSnapshotIfRequested()
        #if DEBUG
        runSnapshotTourIfRequested()
        #endif
    }

    #if DEBUG
    /// Developer aid for checking the UI without screen recording: when
    /// `.june/flare-snapshots/REQUEST` exists in the source tree, a debug build renders every page
    /// into that folder (off screen, at full height) and quits. If the request file contains "live",
    /// a simulated watch (the fakewatch tool built next to this binary) is connected first; its
    /// pointer output goes nowhere, so the real cursor never moves.
    private func runSnapshotTourIfRequested() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".june/flare-snapshots", isDirectory: true)
        let request = folder.appendingPathComponent("REQUEST")
        guard let text = try? String(contentsOf: request, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: request)
        let live = text.contains("live")

        MainActor.assumeIsolated {
            let model = AppModel.shared
            let hadDeveloperLink = model.developerLinkEnabled
            let trustedBefore = Set(model.trustedWatches.map(\.id))
            var fakeWatch: Process?
            var clock = 1.5

            func at(_ delay: Double, _ work: @escaping @MainActor () -> Void) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
            }

            if live {
                at(1) {
                    model.engine.sink = TourNullSink()
                    model.developerLinkEnabled = true
                    let tool = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("fakewatch")
                    if let tool, FileManager.default.isExecutableFile(atPath: tool.path) {
                        let process = Process()
                        process.executableURL = tool
                        process.arguments = ["--seconds", "40", "--name", "Apple Watch"]
                        try? process.run()
                        fakeWatch = process
                    }
                }
                for second in stride(from: 3.0, through: 9.0, by: 1.0) {
                    at(second) {
                        if case .awaitingApproval = model.link { model.approvePairing() }
                        model.engine.sink = TourNullSink()
                    }
                }
                clock = 11
            }

            let pages: [(String, CGFloat)] = [("control", 1180), ("dojo", 900), ("gestures", 900),
                                              ("june", 2350), ("settings", 1250)]
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            at(clock - 0.5) { window.orderFrontRegardless() }
            for (page, height) in pages {
                at(clock) {
                    window.setContentSize(NSSize(width: 1440, height: height))
                    window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
                    window.contentView = NSHostingView(rootView: RootView(model: model, page: Page(rawValue: page)))
                }
                clock += page == "dojo" ? 3.5 : 1.6
                at(clock) {
                    if let data = Self.capture(window) {
                        try? data.write(to: folder.appendingPathComponent("\(page)\(live ? "-live" : "").png"))
                    }
                }
                clock += 0.3
            }
            at(clock + 0.3) {
                window.orderOut(nil)
                fakeWatch?.terminate()
                for watch in model.trustedWatches where !trustedBefore.contains(watch.id) { model.forget(watch) }
                model.developerLinkEnabled = hadDeveloperLink
                try? "done".write(to: folder.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }
    #endif

    /// `--snapshot <file.png> [--after <seconds>]` saves a picture of the main window and quits.
    /// Used to check the UI without needing screen-recording permission.
    private func scheduleSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), args.indices.contains(flag + 1) else { return }
        let path = args[flag + 1]
        let delay = args.firstIndex(of: "--after").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            defer { NSApp.terminate(nil) }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
                  let data = Self.capture(window) else { return }
            try? data.write(to: URL(fileURLWithPath: path))
            // The app's opaque background hides the 3D layer in the composite; save the scene alone too.
            if let content = window.contentView, let scene = Self.firstSceneView(in: content),
               let tiff = scene.snapshot().tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path + ".scene.png"))
            }
        }
    }

    private static func firstSceneView(in view: NSView) -> SCNView? {
        if let found = view as? SCNView { return found }
        for child in view.subviews { if let found = firstSceneView(in: child) { return found } }
        return nil
    }

    /// The window as the user sees it. AppKit cannot cache a Metal-backed view, so a 3D scene
    /// (the Dojo) comes from SceneKit's own snapshot with the SwiftUI layer composited on top.
    private static func capture(_ window: NSWindow) -> Data? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        let scale = window.backingScaleFactor
        func makeBitmap() -> NSBitmapImageRep? {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                       pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = bounds.size
            return rep
        }
        func findSceneView(in view: NSView) -> SCNView? {
            if let found = view as? SCNView { return found }
            for child in view.subviews { if let found = findSceneView(in: child) { return found } }
            return nil
        }
        let sceneView = findSceneView(in: content)
        let sceneImage = sceneView?.snapshot()
        sceneView?.isHidden = true
        defer { sceneView?.isHidden = false }
        guard let overlay = makeBitmap() else { return nil }
        content.cacheDisplay(in: bounds, to: overlay)

        guard let canvas = makeBitmap(), let graphics = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor(srgbRed: 0.949, green: 0.949, blue: 0.961, alpha: 1).setFill()
        bounds.fill()
        if let sceneView, let sceneImage {
            var frame = sceneView.convert(sceneView.bounds, to: content)
            if content.isFlipped { frame.origin.y = bounds.height - frame.maxY }
            sceneImage.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        overlay.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a mouse button held down behind us.
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

#if DEBUG
/// Swallows pointer output during the snapshot tour.
private final class TourNullSink: PointerSink {
    func movePointer(dx: Double, dy: Double) {}
    func button(_ button: MouseButton, isDown: Bool, clickCount: Int) {}
    func scroll(dx: Double, dy: Double) {}
    func shortcut(_ shortcut: SystemShortcut) {}
}
#endif

public struct GauntletApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    public init() {}

    public var body: some Scene {
        Window("Flare", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)

        MenuBarExtra {
            MenuBarContent(model: model, telemetry: model.telemetry)
        } label: {
            Image(nsImage: model.isConnected ? MenuBarIcon.connected : MenuBarIcon.idle)
        }
    }
}

public enum GauntletMain {
    /// Entry point used by the executable target.
    public static func run() {
        GauntletApplication.main()
    }
}
