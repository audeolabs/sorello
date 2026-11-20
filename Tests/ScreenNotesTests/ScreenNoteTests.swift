import CoreGraphics
import Foundation
import ScreenNotes
import Testing

/// ARCHITECTURE.md, section 14, "The note": what each keyframe owns and shows, the summary, the manifest and the
/// contact sheet. The narration is invented.
@Suite struct ScreenNoteTests {
    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    static func note(marks: NoteMarks = NoteMarks(), words: [NoteWord] = [], narration: Narration = .transcribed,
                     duration: Double = 20) -> ScreenNote {
        ScreenNote(startedAt: started, duration: duration, display: CGSize(width: 1440, height: 900),
                   frameSize: CGSize(width: 2560, height: 1600), marks: marks, words: words, narration: narration)
    }

    static let stroke = Stroke(number: 1, points: [TimedPoint(t: 6, x: 0.25, y: 0.5), TimedPoint(t: 6.5, x: 0.5, y: 0.25),
                                                   TimedPoint(t: 7, x: 0.75, y: 0.5)])

    @Test func eachKeyframeOwnsTheWordsAndMarksInItsSpan() {
        let words = [NoteWord(time: 1, text: "Open"), NoteWord(time: 1.4, text: "settings."),
                     NoteWord(time: 6.2, text: "This"), NoteWord(time: 6.6, text: "toggle.")]
        let marks = NoteMarks(strokes: [Self.stroke], clicks: [Click(time: 1.2, x: 0.5, y: 0.5)])
        let note = Self.note(marks: marks, words: words)
        let all = note.keyframes.indices.map { note.content(of: $0) }
        #expect(all.flatMap(\.words) == words)
        #expect(all.flatMap(\.strokes) == [Self.stroke])
        #expect(all.flatMap(\.clicks).count == 1)
        let inked = try! #require(all.first { !$0.strokes.isEmpty })
        #expect(inked.words.map(\.text) == ["This", "toggle."])
    }

    @Test func aPhraseStaysWithTheKeyframeThatHoldsItsEnd() {
        // Unbroken speech across a click's keyframe, then a pause.
        let words = [NoteWord(time: 2, text: "This"), NoteWord(time: 2.6, text: "is"), NoteWord(time: 3.2, text: "one"),
                     NoteWord(time: 3.8, text: "phrase"), NoteWord(time: 15, text: "Then")]
        let note = Self.note(marks: NoteMarks(clicks: [Click(time: 2.2, x: 0, y: 0)]), words: words)
        let owners = note.keyframes.indices.filter { !note.content(of: $0).words.isEmpty }
        #expect(owners.count == 2)
        #expect(note.content(of: owners[0]).words.map(\.text) == ["This", "is", "one", "phrase"])
        #expect(note.content(of: owners[1]).words.map(\.text) == ["Then"])
        #expect(KeyframePlanner.span(of: owners[0], in: note.keyframes).contains(3.8))
    }

    /// A narration the model punctuates as one sentence, spoken over one long stroke: its pauses keep each part beside
    /// the frame it was said over.
    @Test func aLongUnpunctuatedNarrationIsSplitAtItsPauses() {
        let times = [2.6, 2.9, 3.8, 4.5, 7.0, 7.7, 9.8, 10.7, 11.0, 11.8, 12.1, 12.4, 14.1, 14.3, 14.8, 15.5, 16.1, 17.1]
        let words = times.enumerated().map { NoteWord(time: $1, text: $0 == times.count - 1 ? "end." : "word\($0)") }
        let long = Stroke(number: 1, points: stride(from: 1.8, through: 11.4, by: 0.1).map {
            TimedPoint(t: $0, x: 0.2 + $0 / 20, y: 0.5)
        })
        let note = Self.note(marks: NoteMarks(strokes: [long]), words: words, duration: 18.6)
        let said = note.keyframes.indices.map { note.content(of: $0).words.map(\.time) }
        #expect(said.flatMap { $0 } == times, "every word once, in order")
        #expect(said.filter { !$0.isEmpty }.count == 4, "the four parts between pauses")
        for index in note.keyframes.indices {
            for time in said[index] where time < 11.4 {
                #expect(abs(time - note.keyframes[index].time) < 5, "said near the frame it is under")
            }
        }
        #expect(note.keyframes.indices.contains { note.drawing(of: $0).strokes.contains { $0.end < 11.4 } },
                "a frame during the stroke shows it half drawn")
    }

    @Test func aPhraseEndsAtAFullStopAPauseOrEightSeconds() {
        let words = [NoteWord(time: 1, text: "One."), NoteWord(time: 1.3, text: "two"), NoteWord(time: 1.6, text: "three"),
                     NoteWord(time: 2.6, text: "four")]
            + stride(from: 5.0, through: 15, by: 0.5).map { NoteWord(time: $0, text: "on") }
        let phrases = KeyframePlanner.phrases(words).map { $0.map(\.time) }
        #expect(phrases.count == 5)
        #expect(phrases[0] == [1])
        #expect(phrases[1] == [1.3, 1.6])
        #expect(phrases[2] == [2.6])
        #expect(phrases[3].first == 5 && phrases[3].last! - 5 <= 8)
        #expect(phrases[4].last == 15)
    }

    @Test func aStrokeInProgressAtAKeyframeIsDrawnUpToItsTime() {
        let long = Stroke(number: 1, points: (0...40).map { TimedPoint(t: 2 + Double($0) * 0.5, x: 0.5, y: 0.5) })
        let note = Self.note(marks: NoteMarks(strokes: [long]), duration: 30)
        let gap = try! #require(note.keyframes.firstIndex { $0.reasons == [.gap] })
        let drawn = note.drawing(of: gap).strokes
        #expect(drawn.count == 1)
        #expect(drawn[0].points.allSatisfy { $0.t <= note.keyframes[gap].time })
        #expect(note.drawing(of: 0).strokes.isEmpty)
    }

    @Test func theSummarySaysWhereTheNoteIsAndWalksTheKeyframes() {
        let words = [NoteWord(time: 6.2, text: "This"), NoteWord(time: 6.6, text: "toggle.")]
        let marks = NoteMarks(strokes: [Self.stroke], pins: [Pin(number: 1, time: 12, x: 0.5, y: 0.5)],
                              clicks: [Click(time: 3, x: 0.1, y: 0.1)])
        let note = Self.note(marks: marks, words: words)
        let summary = note.summary(folder: "/notes/one", date: "19 Nov 2026 at 14:03")
        #expect(summary.hasPrefix("# Screen note\n"))
        #expect(summary.contains("- Folder: /notes/one\n"))
        #expect(summary.contains("- Recorded: 19 Nov 2026 at 14:03\n"))
        #expect(summary.contains("- Length: 0:20\n"))
        #expect(summary.contains("- Marks: 1 stroke, 1 pin, 1 click\n"))
        #expect(summary.contains("- Narration: transcribed on this Mac\n"))
        #expect(summary.contains("## 1 · 0:00 · frames/frame-01.png\n"))
        #expect(summary.contains("> 0:06 This toggle.\n"))
        #expect(summary.contains("- 0:03 click at (256, 160)\n"))
        #expect(summary.contains("- 0:07 stroke 1 drawn over (640, 400)–(1920, 800)\n"))
        #expect(summary.contains("- 0:12 pin 1 at (1280, 800)\n"))
        #expect(summary.contains(ScreenNote.Files.contactSheet))
    }

    @Test func theSummarySaysWhyThereIsNoTranscript() {
        #expect(Self.note(narration: .noMicrophone).summary(folder: "/n", date: "d")
            .contains("- Narration: none, because Sorello may not use the microphone\n"))
        #expect(Self.note(narration: .notTranscribed("the speech model is not downloaded")).summary(folder: "/n", date: "d")
            .contains("- Narration: recorded but not transcribed: the speech model is not downloaded\n"))
        #expect(Self.note().summary(folder: "/n", date: "d").contains("- Narration: nothing was said\n"))
    }

    @Test func theManifestHoldsEveryPartOfTheNote() throws {
        let marks = NoteMarks(strokes: [Self.stroke], pins: [Pin(number: 1, time: 12, x: 0.5, y: 0.5)],
                              clicks: [Click(time: 3, x: 0.1, y: 0.1)])
        let note = Self.note(marks: marks, words: [NoteWord(time: 6.2, text: "Here.")],
                             narration: .notTranscribed("why"))
        let data = try note.manifest()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["startedAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(json["duration"] as? Double == 20)
        #expect((json["display"] as? [String: Double]) == ["width": 1440, "height": 900])
        #expect((json["frame"] as? [String: Double]) == ["width": 2560, "height": 1600])
        #expect(json["narration"] as? String == "notTranscribed")
        #expect(json["narrationProblem"] as? String == "why")
        let keyframes = try #require(json["keyframes"] as? [[String: Any]])
        #expect(keyframes.first?["file"] as? String == "frames/frame-01.png")
        let strokes = try #require(json["strokes"] as? [[String: Any]])
        #expect(strokes.first?["start"] as? Double == 6)
        #expect(strokes.first?["end"] as? Double == 7)
        #expect((strokes.first?["points"] as? [[Double]])?.first == [6, 0.25, 0.5])
        #expect((json["pins"] as? [[String: Any]])?.count == 1)
        #expect((json["clicks"] as? [[String: Any]])?.count == 1)
        #expect((json["words"] as? [[String: Any]])?.first?["text"] as? String == "Here.")
        #expect(try JSONDecoder().decode(NoteManifest.self, from: data) == NoteManifest(note))
    }

    @Test func theContactSheetIsAGridAtMostFourAcrossInOrder() {
        let layout = ContactSheetLayout(count: 6, frameSize: CGSize(width: 2560, height: 1600))
        #expect(layout.images.count == 6)
        #expect(layout.images[0].width == 640 && layout.images[0].height == 400)
        #expect(layout.images[3].minY == layout.images[0].minY)
        #expect(layout.images[4].minY > layout.images[0].maxY)
        #expect(layout.images[4].minX == layout.images[0].minX)
        #expect(layout.labels[0].minY == layout.images[0].maxY)
        #expect(layout.size.width == CGFloat(16 + 4 * (640 + 16)))
        for frame in layout.images + layout.labels {
            #expect(CGRect(origin: .zero, size: layout.size).contains(frame))
        }
        let one = ContactSheetLayout(count: 1, frameSize: CGSize(width: 1000, height: 1000))
        #expect(one.size.width == CGFloat(16 + 640 + 16))
    }

    @Test func eachKeyframesCaptionIsUnderItsLabelAndARowIsAsTallAsItsLongest() {
        let layout = ContactSheetLayout(count: 6, frameSize: CGSize(width: 2560, height: 1600),
                                        captionHeights: [0, 60, 20, 0, 10, 0])
        #expect(layout.captions.count == 6)
        for index in 0..<6 {
            #expect(layout.captions[index].minY == layout.labels[index].maxY)
            #expect(layout.captions[index].minX == layout.images[index].minX)
            #expect(layout.captions[index].width == 640)
        }
        #expect(layout.captions[1].height == 60)
        #expect(layout.images[4].minY == layout.captions[1].maxY + 16, "the next row starts below the longest caption")
        #expect(layout.size.height == layout.captions[4].minY + 10 + 16)
        for frame in layout.images + layout.labels + layout.captions {
            #expect(CGRect(origin: .zero, size: layout.size).contains(frame))
        }
    }

    @Test func theCaptionIsWhatWasSaidInTheSpan() {
        let words = [NoteWord(time: 1, text: "Open"), NoteWord(time: 1.4, text: "settings."),
                     NoteWord(time: 6.2, text: "This"), NoteWord(time: 6.6, text: "toggle.")]
        let note = Self.note(marks: NoteMarks(strokes: [Self.stroke]), words: words)
        let captions = note.keyframes.indices.map { note.content(of: $0).said }
        #expect(captions.filter { !$0.isEmpty } == ["Open settings.", "This toggle."])
    }

    static let narration = [NoteWord(time: 1, text: "Open"), NoteWord(time: 1.4, text: "settings."),
                            NoteWord(time: 6.2, text: "This"), NoteWord(time: 6.6, text: "toggle.")]

    static func pieces(of note: ScreenNote) throws -> [NotePiece] {
        try JSONDecoder().decode(NoteManifest.self, from: note.manifest()).pieces(folder: "/notes/one")
    }

    static func texts(_ pieces: [NotePiece]) -> [String] {
        pieces.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    /// Section 14, "Pasting a note": with nothing drawn, a line about the note, then each keyframe's number, time and
    /// narration followed by its frame, in order, read back from the manifest.
    @Test func aNoteWithNothingDrawnPastesEveryKeyframesTextAndFrame() throws {
        let note = Self.note(marks: NoteMarks(clicks: [Click(time: 4, x: 0.5, y: 0.5)]), words: Self.narration)
        #expect(note.keyframes.indices.allSatisfy { note.drawing(of: $0).strokes.isEmpty && note.drawing(of: $0).pins.isEmpty })
        let pieces = try Self.pieces(of: note)
        #expect(pieces.count == 2 * note.keyframes.count)
        var texts: [String] = []
        for (index, keyframe) in note.keyframes.enumerated() {
            guard case .text(let text) = pieces[2 * index] else {
                Issue.record("piece \(2 * index) is not text")
                continue
            }
            texts.append(text)
            #expect(text.contains("\(keyframe.number) · \(ScreenNote.clock(keyframe.time))"))
            #expect(pieces[2 * index + 1] == .frame(keyframe.file))
        }
        #expect(texts.first?.hasPrefix("Screen note, 0:20, \(note.keyframes.count) keyframes, in /notes/one") == true)
        for index in note.keyframes.indices {
            let said = note.content(of: index).said
            if !said.isEmpty { #expect(texts[index].contains(said)) }
        }
        #expect(texts.filter { $0.contains("This toggle.") }.count == 1)
        #expect(texts.filter { $0.contains("Open settings.") }.count == 1)
    }

    /// The keyframes with marks of their own: a stroke that ends or a pin dropped in their span.
    static func marked(_ note: ScreenNote) -> [Int] {
        note.keyframes.indices.filter { !note.content(of: $0).strokes.isEmpty || !note.content(of: $0).pins.isEmpty }
    }

    /// With marks, only the keyframes with marks of their own bring their frames; every keyframe's text is still there,
    /// in order, and texts next to each other are one piece.
    @Test func aNoteWithMarksPastesOnlyTheFramesWithMarksOfTheirOwn() throws {
        let pin = Pin(number: 1, time: 15, x: 0.5, y: 0.5)
        let note = Self.note(marks: NoteMarks(strokes: [Self.stroke], pins: [pin]), words: Self.narration)
        let drawn = Self.marked(note)
        #expect(drawn.count == 2)
        #expect(drawn.count < note.keyframes.count)
        let pieces = try Self.pieces(of: note)
        let frames = pieces.compactMap { if case .frame(let file) = $0 { file } else { nil } }
        #expect(frames == drawn.map { note.keyframes[$0].file })
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            if case .text = a, case .text = b { Issue.record("two texts next to each other") }
        }
        let all = Self.texts(pieces).joined()
        var from = all.startIndex
        for keyframe in note.keyframes {
            let label = "\(keyframe.number) · \(ScreenNote.clock(keyframe.time))"
            let found = try #require(all.range(of: label, range: from..<all.endIndex), "\(label) in order")
            from = found.upperBound
        }
        #expect(all.contains("Open settings."))
        #expect(all.contains("This toggle."))
        // Each frame follows the text that ends with its own keyframe's line.
        for (offset, piece) in pieces.enumerated() {
            guard case .frame(let file) = piece, offset > 0, case .text(let before) = pieces[offset - 1] else { continue }
            let keyframe = try #require(note.keyframes.first { $0.file == file })
            let lastLine = before.split(separator: "\n").last.map(String.init) ?? ""
            #expect(lastLine.hasPrefix("\(keyframe.number) · "))
        }
    }

    /// A keyframe taken while a stroke is still being drawn shows it half drawn; only the keyframe where it ends
    /// brings its frame.
    @Test func aKeyframeShowingAStrokeInProgressBringsNoFrame() throws {
        let long = Stroke(number: 1, points: [TimedPoint(t: 2, x: 0.2, y: 0.2), TimedPoint(t: 3, x: 0.3, y: 0.3),
                                              TimedPoint(t: 5, x: 0.4, y: 0.4), TimedPoint(t: 9, x: 0.6, y: 0.2)])
        let words = [NoteWord(time: 3.6, text: "Look"), NoteWord(time: 4, text: "here.")]
        let note = Self.note(marks: NoteMarks(strokes: [long]), words: words)
        let halfDrawn = try #require(note.keyframes.indices.first {
            !note.drawing(of: $0).strokes.isEmpty && note.content(of: $0).strokes.isEmpty
        }, "a keyframe while the stroke is drawn")
        let pieces = try Self.pieces(of: note)
        let frames = pieces.compactMap { if case .frame(let file) = $0 { file } else { nil } }
        #expect(frames == Self.marked(note).map { note.keyframes[$0].file })
        #expect(frames.count == 1)
        #expect(!frames.contains(note.keyframes[halfDrawn].file))
    }

    @Test func timesReadAsMinutesAndSeconds() {
        #expect(ScreenNote.clock(0) == "0:00")
        #expect(ScreenNote.clock(65.9) == "1:05")
        #expect(ScreenNote.clock(3725) == "1:02:05")
    }
}
