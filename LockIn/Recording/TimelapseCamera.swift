import AVFoundation
import UIKit

/// Runs the camera and writes one frame every `interval` seconds into a 30 fps video,
/// which is what turns hours of work into a short timelapse.
final class TimelapseCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let outputFPS: Int32 = 30

    let session = AVCaptureSession()
    @Published private(set) var position: AVCaptureDevice.Position = .front
    @Published private(set) var permissionDenied = false

    private let sessionQueue = DispatchQueue(label: "lockin.camera.session")
    private let frameQueue = DispatchQueue(label: "lockin.camera.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?

    // Only touched on frameQueue.
    private var recording = false
    private var interval: Double = 2
    private var lastFrameTime = CMTime.invalid
    private var frames = 0
    private var outputURL: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerFailed = false

    private struct WriterSnapshot: @unchecked Sendable {
        let writer: AVAssetWriter?
        let input: AVAssetWriterInput?
        let url: URL?
        let frames: Int
    }

    // MARK: Camera lifecycle

    func start() {
        let position = self.position
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession(position: position)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.startSession(position: position)
                } else {
                    DispatchQueue.main.async { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func flip() {
        let newPosition: AVCaptureDevice.Position = position == .front ? .back : .front
        position = newPosition
        sessionQueue.async { self.configure(position: newPosition) }
    }

    private func startSession(position: AVCaptureDevice.Position) {
        sessionQueue.async {
            self.configure(position: position)
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configure(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        if let input {
            session.removeInput(input)
            self.input = nil
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else { return }
        session.addInput(newInput)
        input = newInput

        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
            session.addOutput(videoOutput)
        }
        // Portrait frames, ready for Instagram stories.
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    /// While recording we only need a few frames a second, so drop the sensor rate to save battery and heat.
    private func setLowPowerFrameRate(_ enabled: Bool) {
        guard let device = input?.device else { return }
        do { try device.lockForConfiguration() } catch { return }
        defer { device.unlockForConfiguration() }
        if enabled {
            guard let range = device.activeFormat.videoSupportedFrameRateRanges
                .min(by: { $0.minFrameRate < $1.minFrameRate }) else { return }
            let duration = (range.minFrameRate <= 3 && range.maxFrameRate >= 3)
                ? CMTime(value: 1, timescale: 3)
                : range.maxFrameDuration
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } else {
            device.activeVideoMinFrameDuration = .invalid
            device.activeVideoMaxFrameDuration = .invalid
        }
    }

    // MARK: Recording

    func startRecording(to url: URL, interval: Double) {
        frameQueue.async {
            self.outputURL = url
            self.interval = interval
            self.lastFrameTime = .invalid
            self.frames = 0
            self.writer = nil
            self.writerInput = nil
            self.adaptor = nil
            self.writerFailed = false
            self.recording = true
        }
        sessionQueue.async { self.setLowPowerFrameRate(true) }
    }

    func stopRecording() async -> (url: URL?, frames: Int) {
        let snapshot: WriterSnapshot = await withCheckedContinuation { continuation in
            frameQueue.async {
                self.recording = false
                let snap = WriterSnapshot(writer: self.writer, input: self.writerInput, url: self.outputURL, frames: self.frames)
                self.writer = nil
                self.writerInput = nil
                self.adaptor = nil
                continuation.resume(returning: snap)
            }
        }
        sessionQueue.async { self.setLowPowerFrameRate(false) }

        guard let writer = snapshot.writer, let input = snapshot.input, writer.status == .writing else {
            return (nil, 0)
        }
        guard snapshot.frames > 0 else {
            writer.cancelWriting()
            return (nil, 0)
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? (snapshot.url, snapshot.frames) : (nil, 0)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, !writerFailed else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastFrameTime.isValid, CMTimeGetSeconds(CMTimeSubtract(time, lastFrameTime)) < interval - 0.05 {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if writer == nil {
            makeWriter(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let writer, writer.status == .writing,
              let writerInput, let adaptor,
              writerInput.isReadyForMoreMediaData else { return }

        let presentationTime = CMTime(value: CMTimeValue(frames), timescale: Self.outputFPS)
        if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            frames += 1
            lastFrameTime = time
        }
    }

    private func makeWriter(width: Int, height: Int) {
        guard let url = outputURL else { writerFailed = true; return }
        try? FileManager.default.removeItem(at: url)
        guard let newWriter = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { writerFailed = true; return }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        newInput.expectsMediaDataInRealTime = true
        let newAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: newInput, sourcePixelBufferAttributes: nil)

        guard newWriter.canAdd(newInput) else { writerFailed = true; return }
        newWriter.add(newInput)
        guard newWriter.startWriting() else { writerFailed = true; return }
        newWriter.startSession(atSourceTime: .zero)

        writer = newWriter
        writerInput = newInput
        adaptor = newAdaptor
    }
}
