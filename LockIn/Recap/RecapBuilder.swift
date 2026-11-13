import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Makes everything you share after a session: the cover, the sticker, and the timelapse with stats on it.
@MainActor
enum RecapBuilder {
    /// Pass `includeVideo: false` to only redo the images (much faster, e.g. after picking a new cover frame or style).
    static func build(for session: FocusSession, streak currentStreak: Int, includeVideo: Bool = true) async -> FocusSession {
        var result = session
        let folder = Storage.folder(for: session.id)
        let streak = session.streakAtEnd ?? currentStreak
        let context = await makeContext(for: session, streak: streak)

        if let cover = render(CoverView(template: session.template, context: context), opaque: true),
           let data = cover.jpegData(compressionQuality: 0.92) {
            if (try? data.write(to: folder.appendingPathComponent("cover.jpg"))) != nil {
                result.coverFile = "cover.jpg"
            }
            let thumbSize = CGSize(width: 180, height: 320)
            let thumb = UIGraphicsImageRenderer(size: thumbSize).image { _ in
                cover.draw(in: CGRect(origin: .zero, size: thumbSize))
            }
            if let thumbData = thumb.jpegData(compressionQuality: 0.8),
               (try? thumbData.write(to: folder.appendingPathComponent("thumb.jpg"))) != nil {
                result.thumbFile = "thumb.jpg"
            }
        }

        if let sticker = render(StickerView(session: session, streak: streak), opaque: false),
           let data = sticker.pngData(),
           (try? data.write(to: folder.appendingPathComponent("sticker.png"))) != nil {
            result.stickerFile = "sticker.png"
        }

        if includeVideo, let raw = session.rawVideoURL {
            let size = context.videoSize
            let points = CGSize(width: size.width / 3, height: size.height / 3)
            if let overlay = render(VideoOverlayView(session: session, size: points, streak: streak), opaque: false) {
                let output = folder.appendingPathComponent("share.mp4")
                if await VideoTools.exportWithOverlay(source: raw, to: output, overlay: overlay, session: session) {
                    result.shareVideoFile = "share.mp4"
                }
            }
        }
        return result
    }

    /// Everything a cover template needs: the chosen photo, a blurred copy, a few frames, and the stats.
    static func makeContext(for session: FocusSession, streak: Int) async -> CoverContext {
        var photo: UIImage?
        var frames: [UIImage] = []
        var size = CGSize(width: 1080, height: 1920)
        if let raw = session.rawVideoURL {
            if let info = await VideoTools.inspect(raw, frameAt: session.coverFrameTime) {
                photo = info.thumbnail.map { UIImage(cgImage: $0) }
                size = info.size
            }
            frames = await VideoTools.frames(from: raw, fractions: [0.2, 0.5, 0.8], maxSize: CGSize(width: 540, height: 960))
        }
        let blurred = photo.flatMap { blur($0, radius: 45) }
        return CoverContext(session: session, photo: photo, blurred: blurred, frames: frames, streak: streak, videoSize: size)
    }

    private static func blur(_ image: UIImage, radius: Float) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = radius
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cgImage = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func render<V: View>(_ view: V, opaque: Bool) -> UIImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = opaque
        return renderer.uiImage
    }
}

enum VideoTools {
    struct Info {
        let size: CGSize
        let thumbnail: CGImage?
    }

    static func inspect(_ url: URL, frameAt frameTime: Double? = nil) async -> Info? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let props = try? await track.load(.naturalSize, .preferredTransform),
              let duration = try? await asset.load(.duration) else { return nil }
        let rect = CGRect(origin: .zero, size: props.0).applying(props.1)
        let size = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let total = CMTimeGetSeconds(duration)
        let seconds = min(max(frameTime ?? total * 0.5, 0), max(total - 0.01, 0))
        let thumbnail = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        return Info(size: size, thumbnail: thumbnail)
    }

    /// Joins recorded part files into one timelapse. Unreadable parts are skipped, so one bad part
    /// never costs the rest of the session. Returns the final file and how many frames it has.
    static func assemble(parts: [URL], into output: URL) async -> (url: URL?, frames: Int, log: [String]) {
        var log: [String] = []
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return (nil, 0, ["Couldn't create a video track"])
        }
        var usable: [URL] = []
        var cursor = CMTime.zero
        for url in parts {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .video).first,
                  let range = try? await source.load(.timeRange),
                  CMTimeGetSeconds(range.duration) > 0 else {
                log.append("\(url.lastPathComponent): no readable video, skipped")
                continue
            }
            do {
                try track.insertTimeRange(range, of: source, at: cursor)
                if usable.isEmpty, let transform = try? await source.load(.preferredTransform) {
                    track.preferredTransform = transform
                }
                cursor = CMTimeAdd(cursor, range.duration)
                usable.append(url)
            } catch {
                log.append("\(url.lastPathComponent): couldn't be joined (\(error.localizedDescription))")
            }
        }
        let frames = Int((CMTimeGetSeconds(cursor) * Double(TimelapseCamera.outputFPS)).rounded())
        guard frames > 0 else { return (nil, 0, log + ["No video could be saved"]) }

        // One clean part: use it as-is.
        if usable.count == 1 {
            return (usable[0], frames, log)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return (usable[0], frames, log + ["Couldn't join parts; kept part 1 only"])
        }
        try? FileManager.default.removeItem(at: output)
        var exported = false
        if #available(iOS 18, *) {
            exported = (try? await exporter.export(to: output, as: .mov)) != nil
        } else {
            exporter.outputURL = output
            exporter.outputFileType = .mov
            await exporter.export()
            exported = exporter.status == .completed
        }
        guard exported else {
            return (usable[0], frames, log + ["Couldn't join parts; kept part 1 only"])
        }
        for url in usable { try? FileManager.default.removeItem(at: url) }
        log.append("Joined \(usable.count) parts")
        return (output, frames, log)
    }

    /// Video files left in a session's folder (parts, or an unfinished raw file from older versions).
    static func leftoverVideoFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let parts = files
            .filter { $0.lastPathComponent.hasPrefix("part") && $0.pathExtension == "mov" }
            .sorted { partNumber($0) < partNumber($1) }
        let older = files.filter { ["raw.mp4", "raw.mov"].contains($0.lastPathComponent) }
        return parts + older
    }

    private static func partNumber(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst(4)) ?? 0
    }

    static func fileSizeText(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func frames(from url: URL, fractions: [Double], maxSize: CGSize) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return [] }
        let total = CMTimeGetSeconds(duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        var images: [UIImage] = []
        for fraction in fractions {
            let seconds = max(0, min(total - 0.01, total * fraction))
            if let cg = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                images.append(UIImage(cgImage: cg))
            }
        }
        return images
    }

    /// Burns the stats overlay into the timelapse, drawing the session clock and progress bar
    /// fresh on every frame so the clock rolls smoothly instead of jumping.
    static func exportWithOverlay(source: URL, to output: URL, overlay: UIImage, session: FocusSession) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let overlayImage = overlay.cgImage else { return false }
        let job = OverlayRenderJob(
            asset: asset,
            track: track,
            size: CGSize(width: abs(natural.width), height: abs(natural.height)),
            overlay: overlayImage,
            session: session,
            output: output
        )
        return await Task.detached(priority: .userInitiated) { job.run() }.value
    }
}

/// Reads each timelapse frame, draws the overlay + clock + progress bar on it, and writes it back out.
private final class OverlayRenderJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let size: CGSize
    private let overlay: CGImage
    private let session: FocusSession
    private let output: URL
    private let clockAttributes: [NSAttributedString.Key: Any]

    init(asset: AVAsset, track: AVAssetTrack, size: CGSize, overlay: CGImage, session: FocusSession, output: URL) {
        self.asset = asset
        self.track = track
        self.size = size
        self.overlay = overlay
        self.session = session
        self.output = output
        let fontSize = size.height * OverlayLayout.timerHeight * 0.9
        clockAttributes = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: UIColor.white,
        ]
    }

    func run() -> Bool {
        try? FileManager.default.removeItem(at: output)
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)

        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { return false }
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(session.frameCount, 1)
        var index = 0
        var failed = false

        while !failed, let sample = readerOutput.copyNextSampleBuffer() {
            autoreleasepool {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let progress = totalFrames > 1 ? min(1, Double(index) / Double(totalFrames - 1)) : 1
                draw(on: pixelBuffer, progress: progress)

                while !input.isReadyForMoreMediaData {
                    if writer.status != .writing { failed = true; return }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                    failed = true
                    return
                }
                index += 1
            }
        }

        if failed || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            return false
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }

    private func draw(on pixelBuffer: CVPixelBuffer, progress: Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        let w = CGFloat(width)
        let h = CGFloat(height)
        context.draw(overlay, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Switch to top-left origin so the layout fractions (measured from the top) apply directly.
        context.translateBy(x: 0, y: h)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let inset = w * OverlayLayout.sideInset
        let timerRect = CGRect(x: inset, y: h * OverlayLayout.timerTop, width: w - inset * 2, height: h * OverlayLayout.timerHeight)
        let text = Fmt.clock(session.duration * progress) as NSString
        let textSize = text.size(withAttributes: clockAttributes)
        text.draw(at: CGPoint(x: timerRect.minX, y: timerRect.midY - textSize.height / 2), withAttributes: clockAttributes)

        let barRect = CGRect(x: inset, y: h * OverlayLayout.barTop, width: w - inset * 2, height: h * OverlayLayout.barHeight)
        let radius = barRect.height / 2
        UIColor.white.withAlphaComponent(0.25).setFill()
        UIBezierPath(roundedRect: barRect, cornerRadius: radius).fill()
        let filled = CGRect(x: barRect.minX, y: barRect.minY, width: max(barRect.height, barRect.width * CGFloat(progress)), height: barRect.height)
        Theme.accentUIColor.setFill()
        UIBezierPath(roundedRect: filled, cornerRadius: radius).fill()
    }
}
