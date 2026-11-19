import Foundation

/// The keyboard's capture conversion and page (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture):
/// `StreamingResampler`, `CaptureMessageReader`, `KeyboardRecording` and `CapturePage`.
enum KeyboardDictationAudioTests {
    static var tests: [TestCase] {
        [
            ("resamplesToSixteenKilohertzKeepingTheTone", testResamplesToSixteenKilohertzKeepingTheTone),
            ("resamplesOddRatesKeepingTheTone", testResamplesOddRatesKeepingTheTone),
            ("chunksGiveWhatTheWholeGives", testChunksGiveWhatTheWholeGives),
            ("sixteenKilohertzPassesThrough", testSixteenKilohertzPassesThrough),
            ("whatSixteenKilohertzCannotHoldIsFilteredOut", testWhatSixteenKilohertzCannotHoldIsFilteredOut),
            ("readsWellFormedChunksInOrder", testReadsWellFormedChunksInOrder),
            ("refusesMalformedMessages", testRefusesMalformedMessages),
            ("recordingSealsOnceAndFeedsTheStreamOnce", testRecordingSealsOnceAndFeedsTheStreamOnce),
            ("recordingHoldsAtMostTheMaximumDuration", testRecordingHoldsAtMostTheMaximumDuration),
            ("capturePageReachesNothingOutsideIt", testCapturePageReachesNothingOutsideIt),
        ]
    }

    private static func tone(_ frequency: Double, rate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0 ..< Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    /// The signal's power at `frequency` (Goertzel), normalized so a full-scale sine reads about 0.25.
    private static func power(of samples: [Float], at frequency: Double, rate: Double) -> Double {
        let coefficient = 2 * cos(2 * .pi * frequency / rate)
        var previous = 0.0, beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return power / Double(samples.count * samples.count)
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    private static func resample(_ input: [Float], rate: Double, chunk: Int) -> [Float] {
        var resampler = StreamingResampler(inputRate: rate)
        var output: [Float] = []
        var start = 0
        while start < input.count {
            output += resampler.process(Array(input[start ..< min(start + chunk, input.count)]))
            start += chunk
        }
        return output + resampler.flush()
    }

    private static func expectTone(_ output: [Float], at frequency: Double, file: StaticString = #filePath, line: UInt = #line) {
        let body = Array(output[800 ..< output.count - 800])
        let atTone = power(of: body, at: frequency, rate: 16_000)
        for other in [frequency / 2, frequency * 1.5, frequency * 2, 7_000] where other != frequency {
            TestSupport.expect(atTone > 1_000 * power(of: body, at: other, rate: 16_000),
                               "the tone does not stand out from \(other) Hz", file: file, line: line)
        }
        // The level is kept: a 0.5 sine has an RMS of about 0.354.
        TestSupport.expect(abs(rms(body[...]) - 0.3536) < 0.01, "the tone's level changed: \(rms(body[...]))",
                           file: file, line: line)
    }

    private static func testResamplesToSixteenKilohertzKeepingTheTone() {
        let output = resample(tone(1_000, rate: 48_000, seconds: 1), rate: 48_000, chunk: 4_096)
        TestSupport.expectEqual(output.count, 16_000)
        expectTone(output, at: 1_000)
    }

    private static func testResamplesOddRatesKeepingTheTone() {
        let output = resample(tone(3_000, rate: 44_100, seconds: 1.5), rate: 44_100, chunk: 4_096)
        TestSupport.expectEqual(output.count, 24_000)
        expectTone(output, at: 3_000)
        let low = resample(tone(440, rate: 8_000, seconds: 1), rate: 8_000, chunk: 1_000)
        TestSupport.expectEqual(low.count, 16_000)
        expectTone(low, at: 440)
    }

    private static func testChunksGiveWhatTheWholeGives() {
        let input = tone(700, rate: 48_000, seconds: 0.7)
        let whole = resample(input, rate: 48_000, chunk: input.count)
        for chunk in [1, 333, 4_096, 12_000] {
            let chunked = resample(input, rate: 48_000, chunk: chunk)
            TestSupport.expectEqual(chunked.count, whole.count)
            TestSupport.expect(zip(chunked, whole).allSatisfy { abs($0 - $1) < 1e-5 }, "chunks of \(chunk) differ")
        }
    }

    private static func testSixteenKilohertzPassesThrough() {
        var resampler = StreamingResampler(inputRate: 16_000)
        let input = tone(500, rate: 16_000, seconds: 0.1)
        TestSupport.expectEqual(resampler.process(input), input)
        TestSupport.expectEqual(resampler.flush(), [])
    }

    private static func testWhatSixteenKilohertzCannotHoldIsFilteredOut() {
        for frequency in [9_000.0, 12_000, 20_000] {
            let output = resample(tone(frequency, rate: 48_000, seconds: 0.5), rate: 48_000, chunk: 4_096)
            TestSupport.expect(rms(output[400 ..< output.count - 400]) < 0.005, "\(frequency) Hz folded back into the output")
        }
    }

    private static func chunk(_ sequence: Int, rate: Double = 48_000, samples: [Int16] = [0, 16_384, -32_768, 32_767])
    -> [String: Any] {
        var data = Data()
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return ["kind": "audio", "seq": NSNumber(value: sequence), "rate": NSNumber(value: rate),
                "pcm": data.base64EncodedString()]
    }

    private static func testReadsWellFormedChunksInOrder() {
        var reader = CaptureMessageReader()
        TestSupport.expectEqual(reader.read(chunk(0)), .audio(samples: [0, 0.5, -1, 32_767 / 32_768], rate: 48_000))
        TestSupport.expectEqual(reader.rate, 48_000)
        TestSupport.expectEqual(reader.read(chunk(1)), .audio(samples: [0, 0.5, -1, 32_767 / 32_768], rate: 48_000))
        // As long as 0.25 s, no longer.
        let longest = [Int16](repeating: 1, count: 12_000)
        TestSupport.expectEqual(reader.read(chunk(2, samples: longest)), .audio(samples: longest.map { Float($0) / 32_768 }, rate: 48_000))
        TestSupport.expectEqual(reader.read(["kind": "failed"]), .failed)
        TestSupport.expectEqual(reader.read(["kind": "ended"]), .ended)
    }

    private static func testRefusesMalformedMessages() {
        var reader = CaptureMessageReader()
        _ = reader.read(chunk(0))
        let malformed: [Any] = [
            "audio", 7, ["kind": 1], ["kind": "audioo"], [:] as [String: Any],
            chunk(0),                                              // out of order: a repeat
            chunk(2),                                              // out of order: a gap
            chunk(1, rate: 44_100),                                // another rate
            chunk(1, samples: [Int16](repeating: 0, count: 12_001)), // longer than 0.25 s
            chunk(1, samples: []),                                 // empty
            ["kind": "audio", "seq": 1, "rate": 48_000, "pcm": "AAA"],          // not base64 of whole samples
            ["kind": "audio", "seq": 1, "rate": 48_000, "pcm": "not base64!"],
            ["kind": "audio", "seq": 1, "rate": 48_000, "pcm": "AA=="],         // one byte
            ["kind": "audio", "seq": 1.5, "rate": 48_000, "pcm": "AAA="],
            ["kind": "audio", "seq": true, "rate": 48_000, "pcm": "AAA="],
            ["kind": "audio", "seq": 1, "rate": 48_000.5, "pcm": "AAA="],
            ["kind": "audio", "seq": 1, "rate": 4_000, "pcm": "AAA="],
            ["kind": "audio", "seq": 1, "rate": 500_000, "pcm": "AAA="],
            ["kind": "audio", "seq": 1, "rate": "48000", "pcm": "AAA="],
            ["kind": "audio", "seq": 1, "rate": 48_000],
        ]
        for body in malformed {
            TestSupport.expectEqual(reader.read(body), .malformed)
        }
        // The next well-formed chunk is still taken in order.
        TestSupport.expectEqual(reader.read(chunk(1, samples: [0, 0])), .audio(samples: [0, 0], rate: 48_000))
        // At an odd rate, a quarter of a second is rounded down: 11,025 samples at 44,101 Hz, not 11,026.
        var odd = CaptureMessageReader()
        TestSupport.expectEqual(odd.read(chunk(0, rate: 44_101, samples: [Int16](repeating: 0, count: 11_026))), .malformed)
        TestSupport.expectEqual(odd.read(chunk(0, rate: 44_101, samples: [Int16](repeating: 0, count: 11_025))),
                                .audio(samples: [Float](repeating: 0, count: 11_025), rate: 44_101))
        // An oversized text is refused before it is decoded, even when it is not base64.
        var big = CaptureMessageReader()
        TestSupport.expectEqual(big.read(["kind": "audio", "seq": 0, "rate": 48_000,
                                          "pcm": String(repeating: "A", count: 32_004)]), .malformed)
        // The first chunk must be the first.
        var fresh = CaptureMessageReader()
        TestSupport.expectEqual(fresh.read(chunk(1)), .malformed)
    }

    private static func testRecordingSealsOnceAndFeedsTheStreamOnce() {
        var recording = KeyboardRecording()
        TestSupport.expectEqual(recording.takeForStream(), [])
        let input = tone(1_000, rate: 48_000, seconds: 0.3)
        TestSupport.expect(recording.append(Array(input[..<4_096]), rate: 48_000), "the first chunk was refused")
        TestSupport.expectEqual(recording.captureRate, 48_000)
        let prefix = recording.takeForStream()
        TestSupport.expect(!prefix.isEmpty, "the prefix is empty")
        TestSupport.expectEqual(recording.takeForStream(), [])
        TestSupport.expect(!recording.append(Array(input[4_096...]), rate: 44_100), "a chunk at another rate was kept")
        TestSupport.expect(recording.append(Array(input[4_096...]), rate: 48_000), "a second chunk was refused")
        let rest = recording.takeForStream()
        recording.seal()
        let tail = recording.takeForStream()
        TestSupport.expectEqual(prefix + rest + tail, recording.samples)
        TestSupport.expectEqual(recording.samples.count, 4_800)
        TestSupport.expectEqual(recording.seconds, 0.3)
        // Nothing is kept after the seal; a second seal changes nothing.
        TestSupport.expect(!recording.append(input, rate: 48_000), "a chunk after the seal was kept")
        recording.seal()
        TestSupport.expectEqual(recording.samples.count, 4_800)
        TestSupport.expectEqual(recording.takeForStream(), [])
    }

    private static func testRecordingHoldsAtMostTheMaximumDuration() {
        var recording = KeyboardRecording()
        let second = [Float](repeating: 0.1, count: 16_000)
        for _ in 0 ..< Int(DictationProtocol.maxDictationDuration) + 2 {
            recording.append(second, rate: 16_000)
        }
        recording.seal()
        TestSupport.expectEqual(recording.samples.count, KeyboardRecording.maxSamples)
        TestSupport.expectEqual(recording.seconds, DictationProtocol.maxDictationDuration)
    }

    /// The page is one fixed string whose script reaches nothing outside it: no network API, storage API, frame,
    /// window, or address, and a policy that lets nothing load.
    private static func testCapturePageReachesNothingOutsideIt() {
        let page = CapturePage.html.lowercased()
        let forbidden = [
            "fetch", "xmlhttprequest", "xhr", "websocket", "rtcpeerconnection", "rtcdatachannel", "eventsource", "beacon",
            "localstorage", "sessionstorage", "indexeddb", "caches", "cookie", "storage", "frame", "window", "open(",
            "worker", "import", "eval", "function(\"", "settimeout(\"", "://", "src=", "href", "url(", "<link", "<img",
            "<iframe", "<object", "<embed", "<form", "location", "history", "document.write", "navigator.sendbeacon",
            "postmessage(message, ", "parent", "opener", "srcdoc", "blob:", "data:",
        ]
        for name in forbidden {
            TestSupport.expect(!page.contains(name), "the capture page names \(name)")
        }
        // Its policy lets nothing load and runs only its inline script.
        TestSupport.expect(page.contains(#"content="default-src 'none'; script-src 'unsafe-inline'""#),
                           "the capture page's policy is not default-src 'none' with an inline script")
        // It names only what it may: getUserMedia, Web Audio and the one handler.
        TestSupport.expect(page.contains("navigator.mediadevices.getusermedia("), "the page does not capture")
        TestSupport.expect(page.contains("webkit.messagehandlers.\(CapturePage.handlerName.lowercased()).postmessage("),
                           "the page does not post through the one handler")
        TestSupport.expectEqual(page.components(separatedBy: "messagehandlers.").count, 2)
        TestSupport.expectEqual(page.components(separatedBy: "<script").count, 2)
        TestSupport.expect(page.contains("video: false"), "the page may ask for video")
        // Echo cancellation, noise suppression and automatic gain off.
        for constraint in ["echocancellation: false", "noisesuppression: false", "autogaincontrol: false", "channelcount: 1"] {
            TestSupport.expect(page.contains(constraint), "the page does not ask for \(constraint)")
        }
        TestSupport.expectEqual(CapturePage.baseURL.scheme, "https")
        TestSupport.expect(CapturePage.baseURL.host?.hasSuffix(".invalid") == true, "the origin's domain may resolve")
        TestSupport.expectEqual(CapturePage.baseURL.host, CapturePage.host)
        TestSupport.expect(page.contains(CapturePage.stopScript.lowercased().replacingOccurrences(of: "();", with: "()")),
                           "the page has no stop function")
    }
}
