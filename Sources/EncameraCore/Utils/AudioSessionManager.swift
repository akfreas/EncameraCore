//
//  AudioSessionManager.swift
//  EncameraCore
//

import Foundation
import AVFoundation

/// Owns the app's shared `AVAudioSession`, configured at the point audio is
/// actually needed rather than during launch.
///
/// Encamera plays audio in exactly one place: a decrypted video in the viewer.
/// Configuring the session for that at startup meant every launch interrupted
/// whatever the user was listening to, because activating a session in a
/// non-mixable category stops other apps' audio — and an interrupted music app
/// does not resume when ours goes away.
///
/// `.playback` (rather than `.ambient`) is deliberate: video has to be audible
/// with the ringer switch flipped to silent, which only the playback categories
/// allow. `.mixWithOthers` is what keeps the user's music going.
///
/// Capture has no business here — `AVCaptureSession` configures the session for
/// recording on its own, and already mixes rather than interrupts.
public enum AudioSessionManager: DebugPrintable {

    /// Configures and activates the session for playing a video. Call this as
    /// playback starts, not before.
    @discardableResult
    public static func activateForVideoPlayback() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            logCurrentConfiguration(context: "activated for video playback")
            return true
        } catch {
            printDebug("Failed to activate for video playback:", error)
            return false
        }
    }

    /// Relinquishes the session once playback stops. Best effort: it throws if
    /// something in the app is still playing, which is not worth reacting to.
    @discardableResult
    public static func deactivate() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(false)
            return true
        } catch {
            printDebug("Failed to deactivate session:", error)
            return false
        }
    }

    /// Records what the session actually ended up as, for diagnosing reports of
    /// the app talking over — or silencing — something else.
    public static func logCurrentConfiguration(context: String) {
        let session = AVAudioSession.sharedInstance()
        printDebug("\(context): category=\(session.category.rawValue)",
                   "options=\(session.categoryOptions)",
                   "mixesWithOthers=\(session.categoryOptions.contains(.mixWithOthers))",
                   "otherAudioPlaying=\(session.isOtherAudioPlaying)")
    }
}
