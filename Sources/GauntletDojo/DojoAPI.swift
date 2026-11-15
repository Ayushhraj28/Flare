import SwiftUI
import GauntletProtocol
import GauntletEngine

/// Everything the Dojo needs from the app that hosts it.
///
/// The host owns the engine and the real cursor; the Dojo borrows the engine's output
/// while a sandbox drill is running and hands it back afterwards.
public final class DojoHost {
    public let engine: WristEngine

    /// Ask the watch to play a haptic. No-op when no watch is connected.
    public var playHaptic: (HapticPattern) -> Void = { _ in }

    /// The Dojo changed engine settings (calibration). The host should persist `engine.currentSettings`.
    public var settingsDidChange: () -> Void = {}

    /// Pass a sink to route pointer output into the Dojo's virtual screen (sandbox);
    /// pass nil to give output back to the real macOS cursor.
    public var setSandboxSink: (PointerSink?) -> Void = { _ in }

    /// True while a real, paired watch is streaming. When false the Dojo may drive
    /// the engine with its built-in `VirtualWatch` instead.
    public var isRealWatchConnected: () -> Bool = { false }

    public init(engine: WristEngine) {
        self.engine = engine
    }
}

/// Shared visual language for the Dojo and the Mac app shell: Flare's light theme.
public enum DojoTheme {
    public static let background = Color(red: 0.949, green: 0.949, blue: 0.961)      // #F2F2F5 paper
    public static let panel = Color.white
    public static let panelStroke = Color.black.opacity(0.08)
    public static let accent = Color(red: 1.0, green: 0.478, blue: 0.188)            // #FF7A30 Flare
    public static let secondary = Color(red: 0.761, green: 0.345, blue: 0.122)       // #C2581F ember
    public static let success = Color(red: 0.184, green: 0.659, blue: 0.310)         // #2FA84F
    public static let warning = Color(red: 0.898, green: 0.604, blue: 0.122)         // #E59A1F
    public static let danger = Color(red: 0.898, green: 0.282, blue: 0.302)          // #E5484D
    public static let textPrimary = Color(red: 0.114, green: 0.114, blue: 0.122)     // #1D1D1F ink
    public static let textSecondary = Color(red: 0.369, green: 0.369, blue: 0.400)   // #5E5E66
}
