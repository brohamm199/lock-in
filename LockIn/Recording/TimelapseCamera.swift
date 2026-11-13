import AVFoundation
import UIKit

/// Runs the camera and writes one frame every `interval` seconds into a 30 fps video,
/// which is what turns hours of work into a short timelapse.
///
/// Recording is built to survive failures: video goes into numbered "part" files written as
/// fragmented QuickTime movies (playable up to the last second even if writing dies), and if the
/// encoder ever fails, a new part starts on the next frame instead of giving up.
final class TimelapseCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let outputFPS: Int32 = 30

    let session = AVCaptureSession()
    @Published private(set) var position: AVCaptureDevice.Position = .front
    @Published private(set) var permissionDenied = false
    /// Zoom buttons to show, in "camera app" terms (0.5×, 1×, 2×, 3×).
    @Published private(set) var zoomPresets: [CGFloat] = [1]
    @Published private(set) var displayZoom: CGFloat = 1
    /// Frames saved so far this session (shown live on the recording screen).
    @Published private(set) var framesCaptured = 0

    /// Plain-English events for the session's recording log. Called on the main queue.
    var onEvent: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "tunnel.camera.session")
    private let frameQueue = DispatchQueue(label: "tunnel.camera.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    // Only touched on sessionQueue. zoomBase is the device zoom factor that counts as "1×".
    private var zoomBase: CGFloat = 1
    private var maxZoomFactor: CGFloat = 1

    // Only touched on frameQueue.
    private var recording = false
    private var interval: Double = 2
    private var lastFrameTime = CMTime.invalid
    private var folder: URL?
    private var parts: [URL] = []
    private var partIndex = 0
    private var partFrames = 0
    private var totalFrames = 0
    private var failedStarts = 0
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionWasInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionRuntimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.onEvent?(message) }
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

    /// Used by the stall watchdog: kick the camera if frames stop arriving.
    func restartSession() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.startRunning()
            self.setLowPowerFrameRate(true)
            self.report(self.session.isRunning ? "Camera restarted" : "Camera failed to restart")
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
        guard let device = Self.captureDevice(for: position),
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else { return }
        session.addInput(newInput)
        input = newInput
        configureZoom(device)

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

    // MARK: Interruptions

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
        let text = reason.map(Self.describe) ?? "unknown reason"
        report("Camera paused: \(text)")
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "app went to the background"
        case .audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient: return "another app is using the camera"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "multiple apps on screen"
        case .videoDeviceNotAvailableDueToSystemPressure: return "phone too hot"
        default: return "reason \(reason.rawValue)"
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        report("Camera resumed")
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        report("Camera error: \(error?.localizedDescription ?? "unknown"). Restarting it.")
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    // MARK: Zoom

    /// Back camera: the virtual triple camera, so zooming switches between ultra wide, wide and telephoto.
    private static func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return nil
    }

    private func configureZoom(_ device: AVCaptureDevice) {
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let startsUltraWide = device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera
        let base: CGFloat = startsUltraWide ? (switchOvers.first ?? 1) : 1
        let minFactor = device.minAvailableVideoZoomFactor
        let maxFactor = min(device.maxAvailableVideoZoomFactor, base * 10)

        var presets: Set<CGFloat> = [1]
        if minFactor / base < 0.99 {
            presets.insert((minFactor / base * 10).rounded() / 10)
        }
        for factor in switchOvers where factor / base > 1.01 {
            presets.insert((factor / base * 10).rounded() / 10)
        }
        if maxFactor / base >= 2 {
            presets.insert(2)
        }
        let sortedPresets = presets.filter { $0 * base <= maxFactor + 0.01 }.sorted()

        zoomBase = base
        maxZoomFactor = maxFactor
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = min(max(base, minFactor), maxFactor)
            device.unlockForConfiguration()
        }
        DispatchQueue.main.async {
            self.zoomPresets = sortedPresets
            self.displayZoom = 1
        }
    }

    /// `display` is in camera-app terms: 0.5 = ultra wide, 1 = main lens, 3 = telephoto.
    func setZoom(_ display: CGFloat, animated: Bool) {
        sessionQueue.async {
            guard let device = self.input?.device else { return }
            let factor = min(max(display * self.zoomBase, device.minAvailableVideoZoomFactor), self.maxZoomFactor)
            guard (try? device.lockForConfiguration()) != nil else { return }
            if animated {
                device.ramp(toVideoZoomFactor: factor, withRate: 12)
            } else {
                device.videoZoomFactor = factor
            }
            device.unlockForConfiguration()
            let shown = factor / self.zoomBase
            DispatchQueue.main.async { self.displayZoom = shown }
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

    func startRecording(in folder: URL, interval: Double) {
        frameQueue.async {
            self.folder = folder
            self.interval = interval
            self.lastFrameTime = .invalid
            self.parts = []
            self.partIndex = 0
            self.partFrames = 0
            self.totalFrames = 0
            self.failedStarts = 0
            self.writer = nil
            self.writerInput = nil
            self.adaptor = nil
            self.recording = true
        }
        DispatchQueue.main.async { self.framesCaptured = 0 }
        sessionQueue.async { self.setLowPowerFrameRate(true) }
        report("Recording started (1 frame every \(Int(interval))s)")
    }

    /// Cleanly closes the current part, e.g. before the app goes to the background,
    /// where the video encoder isn't allowed to run. The next frame starts a new part.
    func closeCurrentPart() {
        frameQueue.async { self.finishCurrentPart(completion: nil) }
    }

    /// Stops recording and returns every part file that has video in it, in order.
    func stopRecording() async -> [URL] {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            frameQueue.async {
                self.recording = false
                self.finishCurrentPart { continuation.resume() }
            }
        }
        sessionQueue.async { self.setLowPowerFrameRate(false) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
            frameQueue.async {
                let total = self.totalFrames
                self.report("Recording stopped: \(total) frames in \(self.parts.count) part(s)")
                continuation.resume(returning: self.parts)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastFrameTime.isValid, CMTimeGetSeconds(CMTimeSubtract(time, lastFrameTime)) < interval - 0.05 {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // A failed writer used to end the recording for good. Now: keep what it wrote, start a new part.
        if let current = writer, current.status == .failed || current.status == .cancelled {
            report("Part \(partIndex) stopped (\(current.error?.localizedDescription ?? "unknown error")). Starting a new part.")
            writer = nil
            writerInput = nil
            adaptor = nil
        }
        if writer == nil {
            // Back off if writers keep failing to start, but never give up entirely.
            if failedStarts > 0, lastFrameTime.isValid,
               CMTimeGetSeconds(CMTimeSubtract(time, lastFrameTime)) < min(60, Double(failedStarts) * 5) {
                return
            }
            startPart(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let writer, writer.status == .writing,
              let writerInput, let adaptor,
              writerInput.isReadyForMoreMediaData else { return }

        let presentationTime = CMTime(value: CMTimeValue(partFrames), timescale: Self.outputFPS)
        if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            partFrames += 1
            totalFrames += 1
            lastFrameTime = time
            let count = totalFrames
            if count == 1 { report("First frame saved") }
            DispatchQueue.main.async { self.framesCaptured = count }
        }
    }

    private func startPart(width: Int, height: Int) {
        guard let folder else { return }
        partIndex += 1
        let url = folder.appendingPathComponent("part\(partIndex).mov")
        try? FileManager.default.removeItem(at: url)

        do {
            let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Fragmented movie: if writing dies, everything up to the last fragment is still playable.
            newWriter.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

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

            guard newWriter.canAdd(newInput) else {
                failedStarts += 1
                report("Couldn't set up part \(partIndex)")
                return
            }
            newWriter.add(newInput)
            guard newWriter.startWriting() else {
                failedStarts += 1
                report("Couldn't start part \(partIndex): \(newWriter.error?.localizedDescription ?? "unknown error")")
                return
            }
            newWriter.startSession(atSourceTime: .zero)

            writer = newWriter
            writerInput = newInput
            adaptor = newAdaptor
            partFrames = 0
            failedStarts = 0
            parts.append(url)
            if partIndex > 1 { report("Part \(partIndex) started") }
        } catch {
            failedStarts += 1
            report("Couldn't create part \(partIndex): \(error.localizedDescription)")
        }
    }

    /// Must run on frameQueue.
    private func finishCurrentPart(completion: (() -> Void)?) {
        guard let current = writer, let input = writerInput else {
            completion?()
            return
        }
        writer = nil
        writerInput = nil
        adaptor = nil
        let index = partIndex

        guard current.status == .writing else {
            // Already failed: the fragmented file keeps what was written before the failure.
            report("Part \(index) ended early (\(current.error?.localizedDescription ?? "unknown error"))")
            completion?()
            return
        }
        if partFrames == 0 {
            current.cancelWriting()
            parts.removeAll { $0 == current.outputURL }
            completion?()
            return
        }
        input.markAsFinished()
        current.finishWriting {
            if current.status != .completed {
                self.report("Part \(index) didn't close cleanly (\(current.error?.localizedDescription ?? "unknown error"))")
            }
            completion?()
        }
    }
}
