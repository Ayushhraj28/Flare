import SwiftUI
import GauntletEngine

/// The 3D training environment: a SceneKit sandbox framed by the Dojo page.
public struct DojoView: View {
    @StateObject private var controller: DojoController

    public init(host: DojoHost) {
        self.init(host: host, options: DojoOptions())
    }

    public init(host: DojoHost, options: DojoOptions) {
        _controller = StateObject(wrappedValue: DojoController(host: host, options: options))
    }

    public var body: some View {
        DojoHUD(controller: controller)
            .frame(minWidth: 800, minHeight: 600)
            .environment(\.colorScheme, .light)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }
}
