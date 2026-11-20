import AVFoundation
import CoreGraphics
import CoreText
import DesignCore
import Foundation
import ImageIO
import ScreenNotes
import UniformTypeIdentifiers

/// What a note's movie is, read before its keyframes are chosen.
public struct NoteMovie: Sendable, Equatable {
    /// Seconds.
    public var duration: Double
    /// The video's size in pixels.
    public var size: CGSize
    /// Whether it has a soundtrack.
    public var hasAudio: Bool

    public init(duration: Double, size: CGSize, hasAudio: Bool) {
        self.duration = duration
        self.size = size
        self.hasAudio = hasAudio
    }
}

public enum NoteRenderingFailure: Error, Sendable, Equatable {
    /// The movie has no video, or it could not be read.
    case unreadable
    /// An image could not be written.
    case writeFailed
}

/// Makes a note's images (ARCHITECTURE.md, section 14, "The note", steps 3 and 4): each keyframe decoded from the
/// movie at full size with its marks drawn on it, and the contact sheet.
public struct NoteRenderer: Sendable {
    public init() {}

    /// The movie's length, size and whether it has sound.
    public func inspect(_ movie: URL) async throws(NoteRenderingFailure) -> NoteMovie {
        let asset = AVURLAsset(url: movie)
        do {
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw NoteRenderingFailure.unreadable }
            // The video's own length: the narration may run on after the last frame, and a keyframe needs a frame.
            let (natural, transform, range) = try await video.load(.naturalSize, .preferredTransform, .timeRange)
            let duration = range.end
            let size = natural.applying(transform)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            return NoteMovie(duration: max(duration.seconds, 0), size: CGSize(width: abs(size.width), height: abs(size.height)),
                             hasAudio: !audio.isEmpty)
        } catch {
            throw .unreadable
        }
    }

    /// Writes `frames/frame-NN.png` and `contact-sheet.png` into `folder`.
    public func render(_ note: ScreenNote, movie: URL, folder: URL) async throws(NoteRenderingFailure) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let frames = folder.appendingPathComponent(ScreenNote.Files.frames, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw .writeFailed
        }
        var images: [CGImage] = []
        for index in note.keyframes.indices {
            let keyframe = note.keyframes[index]
            let time = CMTime(seconds: keyframe.time, preferredTimescale: 600)
            let decoded: CGImage
            do {
                decoded = try await generator.image(at: time).image
            } catch {
                // Not exactly there (the last moments of a stream can lack a frame): the nearest frame before it.
                generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
                defer { generator.requestedTimeToleranceBefore = .zero }
                do {
                    decoded = try await generator.image(at: time).image
                } catch {
                    throw .unreadable
                }
            }
            let drawing = note.drawing(of: index)
            guard let image = Self.marked(decoded, strokes: drawing.strokes, pins: drawing.pins) else { throw .writeFailed }
            try Self.writePNG(image, to: frames.appendingPathComponent(Keyframe.fileName(keyframe.number)))
            images.append(image)
        }
        guard let sheet = Self.contactSheet(images, keyframes: note.keyframes) else { throw .writeFailed }
        try Self.writePNG(sheet, to: folder.appendingPathComponent(ScreenNote.Files.contactSheet))
    }

    // MARK: - Drawing

    static let marker = CGColor(srgbRed: Palette.marker.red, green: Palette.marker.green, blue: Palette.marker.blue,
                                alpha: 1)

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// The frame with its strokes and pins drawn on it. Places are fractions from the top left; CoreGraphics draws
    /// from the bottom left.
    static func marked(_ frame: CGImage, strokes: [Stroke], pins: [Pin]) -> CGImage? {
        let width = frame.width, height = frame.height
        guard let context = context(width: width, height: height) else { return nil }
        let w = Double(width), h = Double(height)
        context.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        let line = max(4, w / 400)
        context.setStrokeColor(marker)
        context.setLineWidth(line)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes where stroke.points.count > 1 {
            context.beginPath()
            for (index, point) in stroke.points.enumerated() {
                let place = CGPoint(x: point.x * w, y: (1 - point.y) * h)
                if index == 0 { context.move(to: place) } else { context.addLine(to: place) }
            }
            context.strokePath()
        }
        let radius = max(14, w / 110)
        for pin in pins {
            let center = CGPoint(x: pin.x * w, y: (1 - pin.y) * h)
            context.setFillColor(marker)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(max(2, radius / 7))
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            draw("\(pin.number)", in: context, centeredAt: center, size: radius * 1.1, color: CGColor(gray: 1, alpha: 1))
        }
        return context.makeImage()
    }

    /// The keyframes in a grid, each labelled with its number and time.
    static func contactSheet(_ images: [CGImage], keyframes: [Keyframe]) -> CGImage? {
        guard let first = images.first else { return nil }
        let layout = ContactSheetLayout(count: images.count, frameSize: CGSize(width: first.width, height: first.height))
        let width = Int(layout.size.width), height = Int(layout.size.height)
        guard let context = context(width: width, height: height) else { return nil }
        let h = Double(height)
        context.setFillColor(CGColor(srgbRed: Palette.screen.red, green: Palette.screen.green, blue: Palette.screen.blue,
                                     alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: layout.size.width, height: h))
        context.interpolationQuality = .high
        for (index, image) in images.enumerated() {
            let cell = layout.images[index]
            context.draw(image, in: CGRect(x: cell.minX, y: h - cell.maxY, width: cell.width, height: cell.height))
            let label = layout.labels[index]
            let text = "\(keyframes[index].number) · \(ScreenNote.clock(keyframes[index].time))"
            draw(text, in: context, centeredAt: CGPoint(x: label.midX, y: h - label.midY), size: 18,
                 color: CGColor(gray: 1, alpha: 1))
        }
        return context.makeImage()
    }

    private static func draw(_ text: String, in context: CGContext, centeredAt center: CGPoint, size: Double,
                             color: CGColor) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as [CFString: Any]
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(string)
        // The bounds are measured from the context's text position, which the last line drawn moved.
        context.textPosition = .zero
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: center.x - bounds.width / 2 - bounds.minX,
                                       y: center.y - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws(NoteRenderingFailure) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw .writeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw .writeFailed }
    }
}
