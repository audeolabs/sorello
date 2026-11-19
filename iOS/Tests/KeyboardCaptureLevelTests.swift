import Foundation

/// The in-keyboard wave's meter and the input levels the record keeps (ARCHITECTURE.md, "In-keyboard dictation
/// (experiment)", Phases and Record): the host's meter with its window 15 dB lower, and the loudest and typical chunk
/// level of the sealed recording in whole dBFS. Voices and rooms are invented tones and hiss.
enum KeyboardCaptureLevelTests {
    static var tests: [TestCase] {
        [
            ("quietCaptureVoicesLookActive", testQuietCaptureVoicesLookActive),
            ("quietCaptureRoomsAndPausesRestFlat", testQuietCaptureRoomsAndPausesRestFlat),
            ("theHostMeterIsUnchanged", testTheHostMeterIsUnchanged),
            ("inputLevelsAreTheLoudestAndTheMedianChunk", testInputLevelsAreTheLoudestAndTheMedianChunk),
            ("inputLevelsOfNothingAreUnknown", testInputLevelsOfNothingAreUnknown),
            ("inputLevelsAreBoundedWholeDecibels", testInputLevelsAreBoundedWholeDecibels),
            ("inputLevelsStopAtTheRecordingsCap", testInputLevelsStopAtTheRecordingsCap),
        ]
    }

    private static let rate = 48_000.0
    /// About 85 ms at 48 kHz, as the capture page posts.
    private static let chunk = 4_096

    /// A chunk of a tone whose RMS is `dBFS`.
    private static func tone(at dBFS: Double) -> [Float] {
        let amplitude = Float(2.0.squareRoot() * pow(10, dBFS / 20))
        return (0..<chunk).map { amplitude * sinf(2 * .pi * 220 * Float($0) / Float(rate)) }
    }

    /// A chunk of invented hiss whose RMS is `dBFS`.
    private static func hiss(at dBFS: Double, seed: inout UInt64) -> [Float] {
        let amplitude = Float(3.0.squareRoot() * pow(10, dBFS / 20))
        return (0..<chunk).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return amplitude * (Float(seed >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    /// Invented speech at `dBFS`: syllables a little above it with gaps 18 dB down between. The level after each chunk.
    private static func speak(_ meter: inout LevelMeter, at dBFS: Double, seconds: Double) -> [Float] {
        let pattern = [dBFS + 3, dBFS + 1, dBFS - 18]
        return (0..<Int(seconds * rate / Double(chunk))).map { index in
            meter.update(with: tone(at: pattern[index % pattern.count]))
            return meter.level
        }
    }

    /// WebKit's capture is about 15 dB quieter than the app's, so the host's soft, normal and loud speakers (-32, -22,
    /// -12 dBFS) arrive at -47, -37 and -27 dBFS. Through the keyboard's meter each looks active from its first second:
    /// syllables near the top, clear dips between them.
    private static func testQuietCaptureVoicesLookActive() {
        for dBFS in [-47.0, -37, -27] {
            var meter = LevelMeter.keyboardCapture(sampleRate: rate)
            let levels = speak(&meter, at: dBFS, seconds: 3)
            let first = levels.prefix(12), all = levels.dropFirst(3)
            TestSupport.expect(first.max()! >= 0.85, "a voice at \(dBFS) dBFS starts flat: \(levels)")
            TestSupport.expect(all.max()! >= 0.85, "a voice at \(dBFS) dBFS reads quiet: \(levels)")
            TestSupport.expect(all.max()! - all.min()! >= 0.35, "syllables at \(dBFS) dBFS blur together: \(levels)")
            TestSupport.expect(DotWave.voice(Double(all.max()!)) >= 0.75, "the wave barely swells at \(dBFS) dBFS")
        }
    }

    /// A quiet room in that capture (hiss at -70 and -65 dBFS) rests flat, before anyone speaks and in a pause after a
    /// soft or a loud speaker.
    private static func testQuietCaptureRoomsAndPausesRestFlat() {
        var seed: UInt64 = 11
        for room in [-70.0, -65] {
            for speaker in [nil, -47.0, -27] {
                var meter = LevelMeter.keyboardCapture(sampleRate: rate)
                for _ in 0..<24 {
                    meter.update(with: hiss(at: room, seed: &seed))
                    if speaker == nil { TestSupport.expect(meter.level <= 0.03, "a \(room) dBFS room moves the level: \(meter.level)") }
                }
                guard let speaker else { continue }
                _ = speak(&meter, at: speaker, seconds: 2)
                var pause: [Float] = []
                for _ in 0..<70 {
                    meter.update(with: hiss(at: room, seed: &seed))
                    pause.append(meter.level)
                }
                TestSupport.expect(pause.dropFirst(4).allSatisfy { DotWave.voice(Double($0)) == 0 },
                                   "a pause after \(speaker) dBFS in a \(room) dBFS room swells the wave: \(pause)")
                TestSupport.expect(pause.suffix(24).allSatisfy { $0 <= 0.03 }, "the room creeps up after \(speaker) dBFS: \(pause)")
            }
        }
    }

    /// The host's own meter keeps its -45 dBFS gate: the quiet capture's soft voice stays at rest there, which is why
    /// the keyboard's wave was flat.
    private static func testTheHostMeterIsUnchanged() {
        var meter = LevelMeter(sampleRate: rate)
        let levels = speak(&meter, at: -50, seconds: 2)
        TestSupport.expect(levels.allSatisfy { $0 <= 0.03 }, "the host's meter moved below its gate: \(levels)")
        var keyboard = LevelMeter.keyboardCapture(sampleRate: rate)
        TestSupport.expect(speak(&keyboard, at: -50, seconds: 2).max()! >= 0.5, "the keyboard's meter is not lower")
    }

    /// The loudest chunk's RMS and the median chunk's (the higher middle of an even count), each in whole dBFS.
    private static func testInputLevelsAreTheLoudestAndTheMedianChunk() {
        var levels = KeyboardInputLevels()
        for dBFS in [-52.0, -40, -61, -33, -47] { levels.add(tone(at: dBFS), rate: rate) }
        TestSupport.expectEqual(levels.loudestDBFS, -33)
        TestSupport.expectEqual(levels.typicalDBFS, -47)
        levels.add(tone(at: -44), rate: rate)
        TestSupport.expectEqual(levels.typicalDBFS, -44)
        TestSupport.expectEqual(levels.loudestDBFS, -33)
    }

    /// Before any audio there is nothing to say; an empty chunk adds nothing.
    private static func testInputLevelsOfNothingAreUnknown() {
        var levels = KeyboardInputLevels()
        levels.add([], rate: rate)
        TestSupport.expectEqual(levels.loudestDBFS, nil)
        TestSupport.expectEqual(levels.typicalDBFS, nil)
    }

    /// Digital silence and anything below reads as -120 dBFS, a clipped chunk as 0, and a chunk holding a non-finite
    /// sample adds nothing: the record only ever holds a whole number from -120 to 0.
    private static func testInputLevelsAreBoundedWholeDecibels() {
        var levels = KeyboardInputLevels()
        levels.add([Float](repeating: 0, count: chunk), rate: rate)
        TestSupport.expectEqual(levels.loudestDBFS, -120)
        levels.add([Float](repeating: 4, count: chunk), rate: rate)
        TestSupport.expectEqual(levels.loudestDBFS, 0)
        levels.add([.nan] + [Float](repeating: 0.5, count: chunk - 1), rate: rate)
        TestSupport.expectEqual(levels.loudestDBFS, 0)
        TestSupport.expectEqual(levels.typicalDBFS, 0)
    }

    /// Only the audio the recording keeps counts: past `maxDictationDuration` the recording drops the rest, so a chunk
    /// that crosses the cap counts only its part before it, and a loud tail beyond the cap never becomes the loudest.
    private static func testInputLevelsStopAtTheRecordingsCap() {
        // A low rate keeps five minutes of samples small; the rule is the same at 48 kHz.
        let rate = 1_000.0
        var levels = KeyboardInputLevels()
        let capSamples = Int(DictationProtocol.maxDictationDuration * rate)
        levels.add([Float](repeating: 0.001, count: capSamples - 100), rate: rate)   // -60 dBFS
        levels.add([Float](repeating: 0.001, count: 100) + [Float](repeating: 0.5, count: 300), rate: rate)
        TestSupport.expectEqual(levels.loudestDBFS, -60)
        levels.add([Float](repeating: 0.5, count: 400), rate: rate)
        TestSupport.expectEqual(levels.loudestDBFS, -60)
    }
}
