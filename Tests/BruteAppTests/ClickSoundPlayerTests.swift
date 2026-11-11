import AVFoundation
import XCTest
@testable import BruteApp

@MainActor
final class ClickSoundPlayerTests: XCTestCase {
    func testFeedbackPlaysOnceEngineIsRunning() {
        let engine = FakeClickEngine()
        engine.isRunning = true
        let player = ClickSoundPlayer(engine: engine, observesLifecycle: false)

        player.play()

        XCTAssertEqual(engine.playCount, 1)
        XCTAssertEqual(engine.startCount, 0, "A running engine must not be restarted per play")
    }

    func testStoppedEngineIsStartedOnceAndThenUsed() {
        let engine = FakeClickEngine()
        engine.isRunning = false
        let player = ClickSoundPlayer(engine: engine, observesLifecycle: false)

        player.play()
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.playCount, 1, "A successful start plays the click that triggered it")

        player.play()
        XCTAssertEqual(engine.startCount, 1, "Already running: no second start")
        XCTAssertEqual(engine.playCount, 2)
    }

    func testPlayIsDroppedWhenEngineCannotStart() {
        let engine = FakeClickEngine()
        engine.isRunning = false
        engine.startSucceeds = false
        let player = ClickSoundPlayer(engine: engine, observesLifecycle: false)

        player.play()

        XCTAssertEqual(engine.playCount, 0, "Never schedule buffers onto an engine that is not running")
    }

    func testOutputConfigurationChangeRebuildsGraphAfterDelay() {
        let engine = FakeClickEngine()
        let player = ClickSoundPlayer(engine: engine, observesLifecycle: false, rebuildDelay: 0.01)
        let rebuilt = expectation(description: "fresh graph after the output change")
        engine.onRebuild = { rebuilt.fulfill() }

        engine.fireConfigurationChange()

        XCTAssertTrue(player.isRebuildScheduled)
        XCTAssertEqual(engine.rebuildCount, 0)
        XCTAssertEqual(engine.startCount, 0)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(engine.rebuildCount, 1)
        XCTAssertFalse(player.isRebuildScheduled)
    }

    func testWakeAndOutputChangeShareOnePendingRebuild() {
        let engine = FakeClickEngine()
        let player = ClickSoundPlayer(
            engine: engine,
            observesLifecycle: false,
            rebuildDelay: 0.01
        )

        let rebuilt = expectation(description: "engine rebuilt after the wake delay")
        engine.onRebuild = { rebuilt.fulfill() }

        player.scheduleRebuild()
        engine.fireConfigurationChange()

        XCTAssertTrue(player.isRebuildScheduled)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(engine.rebuildCount, 1)
        XCTAssertFalse(player.isRebuildScheduled)
    }

    func testShutdownCancelsPendingRebuildAndStopsFeedback() {
        let engine = FakeClickEngine()
        let player = ClickSoundPlayer(engine: engine, observesLifecycle: false, rebuildDelay: 0.01)
        engine.fireConfigurationChange()
        XCTAssertTrue(player.isRebuildScheduled)

        player.shutdown()
        engine.fireConfigurationChange()
        player.play()

        XCTAssertFalse(player.isRebuildScheduled)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertEqual(engine.playCount, 0)
    }

    func testSynthesizedClickHasExpectedDurationAndBoundedSignal() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let click = ClickSoundPlayer.makeClickBuffer(format: format, sampleRate: 44_100)
        let samples = click.floatChannelData![0]

        XCTAssertEqual(click.frameLength, AVAudioFrameCount(44_100 * 0.03))
        XCTAssertTrue((0..<Int(click.frameLength)).allSatisfy { abs(samples[$0]) <= 1 })
        XCTAssertTrue((0..<Int(click.frameLength)).contains { abs(samples[$0]) > 0.1 })
    }
}

@MainActor
private final class FakeClickEngine: ClickSoundEngineing {
    var isRunning = false
    var startSucceeds = true
    var configurationChangeHandler: (@MainActor () -> Void)?

    var startCount = 0
    var stopCount = 0
    var rebuildCount = 0
    var playCount = 0
    var onRebuild: (() -> Void)?

    func start() {
        startCount += 1
        if startSucceeds { isRunning = true }
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func rebuild() {
        rebuildCount += 1
        onRebuild?()
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        playCount += 1
    }

    func fireConfigurationChange() {
        configurationChangeHandler?()
    }
}
