// AgentsTests/WakeMicTests.swift
import XCTest

@testable import Agents

/// The arithmetic under the wake mic. A window off by a few hundred samples
/// does not crash anything: the model just scores 0, or scores the wrong
/// end of the audio, forever and without a word.
final class WakeMicTests: XCTestCase {
    /// Samples numbered from `from`, so a window can be checked for order.
    private func ramp(_ range: Range<Int>) -> [Int16] {
        range.map { Int16(truncatingIfNeeded: $0) }
    }

    /// Nothing to score until there are two whole seconds: `predict` returns
    /// 0 for less.
    func testNoWindowUntilTwoSecondsAreIn() {
        var window = WakeWindow()
        var total = 0
        // The mic's chunks: about 1024 frames at 48 kHz, once at 16 kHz.
        while total + 341 < WakeWindow.size {
            XCTAssertNil(window.append(ramp(total..<(total + 341))))
            total += 341
        }
        XCTAssertNil(window.append(ramp(total..<(WakeWindow.size - 1))))
        let full = window.append(ramp((WakeWindow.size - 1)..<WakeWindow.size))
        XCTAssertEqual(full, ramp(0..<WakeWindow.size))
    }

    /// Exactly 32 000 samples, the NEWEST, oldest first - past the ring's wrap.
    func testTheWindowIsTheLastTwoSecondsOldestFirst() {
        var window = WakeWindow()
        _ = window.append(ramp(0..<WakeWindow.size))
        let next = window.append(ramp(WakeWindow.size..<(WakeWindow.size + WakeWindow.hop)))
        XCTAssertEqual(next?.count, 32_000)
        XCTAssertEqual(next, ramp(WakeWindow.hop..<(WakeWindow.size + WakeWindow.hop)))
    }

    func testScoresEveryEightyMilliseconds() {
        var window = WakeWindow()
        XCTAssertNotNil(window.append(ramp(0..<WakeWindow.size)))
        XCTAssertNil(window.append(ramp(0..<(WakeWindow.hop - 1))))
        XCTAssertNotNil(window.append(ramp(0..<1)))
        XCTAssertNil(window.append(ramp(0..<1)))
        XCTAssertEqual(WakeWindow.hop, 1_280, "80 ms at 16 kHz")
        XCTAssertEqual(WakeWindow.scoresPerTwoSeconds, 25)
    }

    /// Never more than the window, which `predict` would cut from the wrong end.
    func testAChunkLongerThanTheWindowKeepsTheNewest() {
        var window = WakeWindow()
        let all = window.append(ramp(0..<40_000))
        XCTAssertEqual(all, ramp(8_000..<40_000))
    }

    func testThePeakIsTheHighestOfEachStretch() {
        var peak = WakePeak(every: 3)
        XCTAssertNil(peak.add(0.1))
        XCTAssertNil(peak.add(0.4))
        XCTAssertEqual(peak.add(0.2), 0.4)
        // And starts over: the last stretch's peak does not carry.
        XCTAssertNil(peak.add(0.05))
        XCTAssertNil(peak.add(0.01))
        XCTAssertEqual(peak.add(0.03), 0.05)
    }

    /// Room for a buffer once it is 16 kHz, from whatever rate the mic runs
    /// at, plus the resampler's slack. Too little and the converter keeps the
    /// rest back, a buffer late.
    func testConverterCapacity() {
        XCTAssertEqual(WakeConverter.capacity(frames: 1_024, rate: 48_000), 350)  // 341.3 → 342
        XCTAssertEqual(WakeConverter.capacity(frames: 4_800, rate: 48_000), 1_608)
        XCTAssertEqual(WakeConverter.capacity(frames: 1_024, rate: 44_100), 380)  // 371.5 → 372
        XCTAssertEqual(WakeConverter.capacity(frames: 1_024, rate: 16_000), 1_032)
        XCTAssertEqual(WakeConverter.capacity(frames: 1_024, rate: 8_000), 2_056)
    }
}
