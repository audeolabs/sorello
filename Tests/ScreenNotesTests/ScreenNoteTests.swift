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

    @Test func aSentenceStaysWithTheKeyframeThatHoldsItsEnd() {
        let words = [NoteWord(time: 1, text: "This"), NoteWord(time: 4, text: "is"), NoteWord(time: 7.5, text: "long."),
                     NoteWord(time: 15, text: "Then")]
        let note = Self.note(marks: NoteMarks(clicks: [Click(time: 3, x: 0, y: 0)]), words: words)
        let owners = note.keyframes.indices.filter { !note.content(of: $0).words.isEmpty }
        #expect(owners.count == 2)
        #expect(note.content(of: owners[0]).words.map(\.text) == ["This", "is", "long."])
        #expect(note.content(of: owners[1]).words.map(\.text) == ["Then"])
        #expect(KeyframePlanner.span(of: owners[0], in: note.keyframes).contains(7.5))
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
        #expect(summary.contains("> This toggle.\n"))
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

    @Test func timesReadAsMinutesAndSeconds() {
        #expect(ScreenNote.clock(0) == "0:00")
        #expect(ScreenNote.clock(65.9) == "1:05")
        #expect(ScreenNote.clock(3725) == "1:02:05")
    }
}
