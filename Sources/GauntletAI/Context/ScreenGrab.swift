import AppKit
import ScreenCaptureKit

/// Takes a picture of the screen for "what's on my screen" and "what's this chart", leaving June's
/// own window out of it. Needs the Screen Recording permission; macOS asks the first time.
enum ScreenGrab {
    struct Shot: Sendable {
        var jpeg: Data
        /// What was captured, in global top-left coordinates (for the capture highlight).
        var frame: CGRect
    }

    /// `around` a point: a 1400×900 region centred on it. `nil`: the whole display under the pointer.
    static func capture(around point: CGPoint?, cursor: CGPoint) async throws -> Shot {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw JuneError.screenRecordingDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(cursor) }) ?? content.displays.first else {
            throw JuneError.screenRecordingDenied
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        var region = display.frame
        if let point {
            region = CGRect(x: point.x - 700, y: point.y - 450, width: 1400, height: 900).intersection(display.frame)
        }
        let local = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        // Keep the image modest: big enough to read text, small enough to upload quickly.
        let scale = min(1.0, 1600 / max(local.width, 1))
        config.sourceRect = local
        config.width = max(1, Int(local.width * scale * 2))
        config.height = max(1, Int(local.height * scale * 2))
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw JuneError.screenRecordingDenied
        }
        return Shot(jpeg: jpeg, frame: region)
    }
}
