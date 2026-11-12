import AVFoundation
import SwiftUI
import UIKit

/// Makes everything you share after a session: the cover, the sticker, and the timelapse with stats on it.
@MainActor
enum RecapBuilder {
    /// Pass `includeVideo: false` to only redo the images (much faster, e.g. after picking a new cover frame).
    static func build(for session: FocusSession, streak currentStreak: Int, includeVideo: Bool = true) async -> FocusSession {
        var result = session
        let folder = Storage.folder(for: session.id)
        let streak = session.streakAtEnd ?? currentStreak

        var background: UIImage?
        var videoSize = CGSize(width: 1080, height: 1920)
        if let raw = session.rawVideoURL, let info = await VideoTools.inspect(raw, frameAt: session.coverFrameTime) {
            background = info.thumbnail.map { UIImage(cgImage: $0) }
            videoSize = info.size
        }

        if let cover = render(CoverView(session: session, background: background, streak: streak), opaque: true),
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
            let points = CGSize(width: videoSize.width / 3, height: videoSize.height / 3)
            if let overlay = render(VideoOverlayView(session: session, size: points, streak: streak), opaque: false) {
                let output = folder.appendingPathComponent("share.mp4")
                if await VideoTools.exportWithOverlay(source: raw, to: output, overlay: overlay, session: session) {
                    result.shareVideoFile = "share.mp4"
                }
            }
        }
        return result
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

    /// Burns the stats overlay, a ticking session clock and a progress bar into the timelapse.
    static func exportWithOverlay(source: URL, to output: URL, overlay: UIImage, session: FocusSession) async -> Bool {
        let asset = AVURLAsset(url: source)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
            let props = try await track.load(.naturalSize, .preferredTransform)
            let duration = try await asset.load(.duration)
            let rect = CGRect(origin: .zero, size: props.0).applying(props.1)
            let size = CGSize(width: abs(rect.width), height: abs(rect.height))
            let seconds = max(CMTimeGetSeconds(duration), 0.1)

            let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            composition.renderSize = size
            composition.frameDuration = CMTime(value: 1, timescale: TimelapseCamera.outputFPS)

            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: size)
            let videoLayer = CALayer()
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)

            let overlayLayer = CALayer()
            overlayLayer.frame = parent.frame
            overlayLayer.contents = overlay.cgImage
            overlayLayer.contentsGravity = .resize
            parent.addSublayer(overlayLayer)

            // Core Animation's origin is the bottom-left corner here, so flip the "from top" layout values.
            func slot(top: CGFloat, height: CGFloat) -> CGRect {
                let inset = size.width * OverlayLayout.sideInset
                return CGRect(
                    x: inset,
                    y: size.height * (1 - top - height),
                    width: size.width - inset * 2,
                    height: size.height * height
                )
            }

            // Ticking clock: a flipbook of pre-drawn times.
            let timerRect = slot(top: OverlayLayout.timerTop, height: OverlayLayout.timerHeight)
            let frameCount = min(150, max(2, Int(seconds * 10)))
            let clockImages = makeClockImages(total: session.duration, count: frameCount, size: timerRect.size)
            let timerLayer = CALayer()
            timerLayer.frame = timerRect
            timerLayer.contentsGravity = .resize
            timerLayer.contents = clockImages.last
            let tick = CAKeyframeAnimation(keyPath: "contents")
            tick.values = clockImages
            tick.calculationMode = .discrete
            tick.beginTime = AVCoreAnimationBeginTimeAtZero
            tick.duration = seconds
            tick.isRemovedOnCompletion = false
            tick.fillMode = .both
            timerLayer.add(tick, forKey: "tick")
            parent.addSublayer(timerLayer)

            // Progress bar that fills over the video.
            let barRect = slot(top: OverlayLayout.barTop, height: OverlayLayout.barHeight)
            let barTrack = CALayer()
            barTrack.frame = barRect
            barTrack.backgroundColor = UIColor.white.withAlphaComponent(0.25).cgColor
            barTrack.cornerRadius = barRect.height / 2
            parent.addSublayer(barTrack)

            let barFill = CALayer()
            barFill.anchorPoint = CGPoint(x: 0, y: 0.5)
            barFill.frame = barRect
            barFill.backgroundColor = Theme.accentUIColor.cgColor
            barFill.cornerRadius = barRect.height / 2
            let grow = CABasicAnimation(keyPath: "transform.scale.x")
            grow.fromValue = 0.001
            grow.toValue = 1.0
            grow.beginTime = AVCoreAnimationBeginTimeAtZero
            grow.duration = seconds
            grow.isRemovedOnCompletion = false
            grow.fillMode = .both
            barFill.add(grow, forKey: "grow")
            parent.addSublayer(barFill)

            composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                return false
            }
            exporter.videoComposition = composition
            try? FileManager.default.removeItem(at: output)

            if #available(iOS 18, *) {
                try await exporter.export(to: output, as: .mp4)
                return true
            } else {
                exporter.outputURL = output
                exporter.outputFileType = .mp4
                await exporter.export()
                return exporter.status == .completed
            }
        } catch {
            return false
        }
    }

    private static func makeClockImages(total: TimeInterval, count: Int, size: CGSize) -> [CGImage] {
        // Drawn at 60% size to keep memory low; the layer scales them up.
        let drawSize = CGSize(width: (size.width * 0.6).rounded(), height: (size.height * 0.6).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: drawSize, format: format)
        let font = UIFont.monospacedDigitSystemFont(ofSize: drawSize.height * 0.9, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]

        return (0..<count).compactMap { i in
            let t = total * Double(i) / Double(max(count - 1, 1))
            let text = Fmt.clock(t) as NSString
            let image = renderer.image { _ in
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: 0, y: (drawSize.height - textSize.height) / 2), withAttributes: attributes)
            }
            return image.cgImage
        }
    }
}
