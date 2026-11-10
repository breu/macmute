import CoreAudio
import XCTest
@testable import BruteApp

@MainActor
final class AudioControlPolicyTests: XCTestCase {
    func testControlResolutionRejectsPartialChannelCoverage() {
        XCTAssertEqual(
            AudioControlPolicy.resolveWritableControlElements(
                mainAvailable: false,
                mainSettable: false,
                inputElements: [1, 2],
                availableChannelElements: [1],
                settableChannelElements: [1]
            ),
            []
        )
        XCTAssertEqual(
            AudioControlPolicy.resolveWritableControlElements(
                mainAvailable: false,
                mainSettable: false,
                inputElements: [1, 2],
                availableChannelElements: [1, 2],
                settableChannelElements: [1]
            ),
            []
        )
    }

    func testControlResolutionUsesCompleteChannelsOrAggregateMain() {
        XCTAssertEqual(
            AudioControlPolicy.resolveWritableControlElements(
                mainAvailable: false,
                mainSettable: false,
                inputElements: [1, 2],
                availableChannelElements: [1, 2],
                settableChannelElements: [1, 2]
            ),
            [1, 2]
        )
        XCTAssertEqual(
            AudioControlPolicy.resolveWritableControlElements(
                mainAvailable: true,
                mainSettable: true,
                inputElements: [1, 2],
                availableChannelElements: [],
                settableChannelElements: []
            ),
            [kAudioObjectPropertyElementMain]
        )
    }

    func testAtomicElementWriteRollsBackChangedElementsInReverseOrder() {
        var values: [UInt32: Int] = [1: 10, 2: 20, 3: 30]
        var writes: [(UInt32, Int)] = []
        let succeeded = AudioControlPolicy.performAtomicWrite(
            elements: [1, 2, 3],
            priorValues: values,
            desiredValues: [1: 0, 2: 0, 3: 0]
        ) { element, value in
            writes.append((element, value))
            if element == 3 && value == 0 { return false }
            values[element] = value
            return true
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(values, [1: 10, 2: 20, 3: 30])
        XCTAssertEqual(writes.map(\.0), [1, 2, 3, 2, 1])
    }

    func testAtomicElementWriteRejectsMismatchedElementSetsWithoutWriting() {
        var writeCount = 0
        XCTAssertFalse(
            AudioControlPolicy.performAtomicWrite(
                elements: [1, 2],
                priorValues: [1: 1, 2: 1],
                desiredValues: [1: 0]
            ) { _, _ in
                writeCount += 1
                return true
            }
        )
        XCTAssertEqual(writeCount, 0)
    }

    func testReadableControlResolutionPrefersReadOnlyAggregateMain() {
        XCTAssertEqual(
            AudioControlPolicy.resolveReadableControlElements(
                mainAvailable: true,
                inputElements: [1, 2],
                availableChannelElements: [1, 2]
            ),
            [kAudioObjectPropertyElementMain]
        )
        XCTAssertEqual(
            AudioControlPolicy.resolveWritableControlElements(
                mainAvailable: true,
                mainSettable: false,
                inputElements: [1, 2],
                availableChannelElements: [1, 2],
                settableChannelElements: [1, 2]
            ),
            [1, 2]
        )
    }
}
