//
//  AudioSessionManagerTests.swift
//  EncameraCoreTests
//

import XCTest
import AVFoundation
@testable import EncameraCore

/// Regression guards for "opening Encamera silences the user's music". The app
/// used to set a bare `.playback` category and activate it during launch, which
/// interrupts every other app's audio session. Playback now configures the
/// session at the point a video starts, and the category it installs has to stay
/// mixable.
final class AudioSessionManagerTests: XCTestCase {

    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    override func setUp() {
        super.setUp()
        // Start from the non-mixing category the app used to install, so a
        // passing assertion cannot be an artifact of whatever ran before.
        try? session.setCategory(.playback, mode: .default, options: [])
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
    }

    override func tearDown() {
        super.tearDown()
        AudioSessionManager.deactivate()
    }

    func testVideoPlaybackMixesWithOtherApps() {
        XCTAssertTrue(AudioSessionManager.activateForVideoPlayback())

        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers),
                      "Playback without .mixWithOthers interrupts other apps' audio")
    }

    /// `.playback` rather than `.ambient` is what keeps video audible when the
    /// ringer switch is on silent — the reason the category exists at all.
    func testVideoPlaybackUsesPlaybackCategoryAndMoviePlaybackMode() {
        AudioSessionManager.activateForVideoPlayback()

        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .moviePlayback)
    }

    func testDeactivateSucceedsAfterPlaybackActivation() {
        AudioSessionManager.activateForVideoPlayback()

        XCTAssertTrue(AudioSessionManager.deactivate())
    }
}
