import Foundation
import AVFoundation
import GauntletLink

/// Owns the one microphone June listens through and shares its audio with every listener, so the
/// wake word, push-to-talk and follow-ups never open the microphone twice. The source runs only
/// while someone is subscribed; switching sources keeps every subscriber attached.
final class AudioHub: @unchecked Sendable {
    typealias Handler = (AVAudioPCMBuffer) -> Void

    private let lock = NSLock()
    private var subscribers: [UUID: Handler] = [:]
    private var running: VoiceAudioSource?
    /// Smoothed input level 0...1 for the June window's orb.
    private var levelValue: Float = 0

    var level: Float { lock.lock(); defer { lock.unlock() }; return levelValue }
    var runningSourceName: String? { lock.lock(); defer { lock.unlock() }; return running?.displayName }

    /// Adds a listener. Starts `source` if nothing is running yet.
    func subscribe(source: VoiceAudioSource, _ handler: @escaping Handler) throws -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = handler
        let needsStart = running == nil
        lock.unlock()
        if needsStart {
            do {
                try start(source)
            } catch {
                lock.lock(); subscribers[id] = nil; lock.unlock()
                throw error
            }
        }
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock()
        subscribers[id] = nil
        let empty = subscribers.isEmpty
        let source = empty ? running : nil
        if empty { running = nil; levelValue = 0 }
        lock.unlock()
        source?.stop()
    }

    /// Moves every listener to another microphone (`force` restarts the same one, e.g. after the
    /// Mac's default input changed to AirPods).
    func switchTo(_ source: VoiceAudioSource, force: Bool = false) {
        lock.lock()
        let current = running
        let hasListeners = !subscribers.isEmpty
        lock.unlock()
        guard hasListeners, force || current !== source else { return }
        current?.stop()
        lock.lock(); running = nil; lock.unlock()
        do {
            try start(source)
            JuneLog.write("microphone switched to \(source.displayName)")
        } catch {
            JuneLog.write("microphone switch to \(source.displayName) failed: \(error)")
            if let current { try? start(current) }
        }
    }

    func stopAll() {
        lock.lock()
        subscribers = [:]
        let source = running
        running = nil
        levelValue = 0
        lock.unlock()
        source?.stop()
    }

    private func start(_ source: VoiceAudioSource) throws {
        try source.start { [weak self] buffer in self?.distribute(buffer) }
        lock.lock(); running = source; lock.unlock()
    }

    private func distribute(_ buffer: AVAudioPCMBuffer) {
        var rms: Float = 0
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += samples[i] * samples[i] }
            rms = (sum / Float(n)).squareRoot()
        }
        lock.lock()
        let normalized = min(1, rms * 12)
        levelValue = levelValue * 0.6 + normalized * 0.4
        let handlers = Array(subscribers.values)
        lock.unlock()
        for handler in handlers { handler(buffer) }
    }
}
