import SwiftUI
import UIKit

/// Drives one session from setup → countdown → recording → recap.
@MainActor
final class SessionController: ObservableObject {
    enum Phase: Equatable {
        case setup
        case countdown(Int)
        case recording
        case finishing
        case done(FocusSession)
    }

    @Published var phase: Phase = .setup
    @Published var title = ""
    @Published var frameInterval: Double = 2
    @Published var showTimer = true
    @Published private(set) var startDate: Date?
    @Published private(set) var isPickedUp = false
    @Published private(set) var pickupCount = 0
    /// True when no new frames have arrived for a while — shown as a warning on the black screen.
    @Published private(set) var cameraStalled = false

    let camera = TimelapseCamera()
    private var log: [String] = []
    private var watchdogTask: Task<Void, Never>?
    private let detector = PickupDetector()
    private let sessionID = UUID()
    private var distractions: [DistractionInterval] = []
    private var openDistraction: (start: TimeInterval, kind: DistractionInterval.Kind)?
    private var savedBrightness: CGFloat?
    private var countdownTask: Task<Void, Never>?

    var isImmersive: Bool {
        switch phase {
        case .countdown, .recording: return true
        default: return false
        }
    }

    init() {
        detector.onPickup = { [weak self] in
            MainActor.assumeIsolated { self?.handlePickup() }
        }
        detector.onSettled = { [weak self] in
            MainActor.assumeIsolated { self?.handleSettled() }
        }
        camera.onEvent = { [weak self] message in
            MainActor.assumeIsolated { self?.addLog(message) }
        }
    }

    private func addLog(_ message: String) {
        let stamp = startDate == nil ? "--:--" : Fmt.clock(elapsed)
        log.append("\(stamp)  \(message)")
    }

    /// Checks every few seconds that frames are still arriving; restarts the camera if they stop.
    private func startWatchdog() {
        watchdogTask?.cancel()
        let allowedGap = max(20, frameInterval * 8)
        watchdogTask = Task { [weak self] in
            var lastCount = 0
            var lastProgress = Date()
            var restarts = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.phase == .recording else { return }
                let count = self.camera.framesCaptured
                if count > lastCount {
                    lastCount = count
                    lastProgress = Date()
                    restarts = 0
                    if self.cameraStalled {
                        self.cameraStalled = false
                        self.addLog("Frames are coming in again")
                    }
                } else if Date().timeIntervalSince(lastProgress) > allowedGap {
                    if !self.cameraStalled {
                        self.cameraStalled = true
                        self.addLog("No new frames for \(Int(allowedGap))s")
                    }
                    if restarts < 5 {
                        restarts += 1
                        self.camera.restartSession()
                    }
                    lastProgress = Date()
                }
            }
        }
    }

    // MARK: Flow

    func prepare() {
        UIApplication.shared.isIdleTimerDisabled = true
        camera.start()
    }

    func begin() {
        guard phase == .setup else { return }
        countdownTask = Task { [weak self] in
            for n in stride(from: 5, through: 1, by: -1) {
                self?.phase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.startRecording()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        phase = .setup
    }

    private func startRecording() {
        startDate = Date()
        log = []
        cameraStalled = false
        camera.startRecording(in: Storage.folder(for: sessionID), interval: frameInterval)
        distractions = []
        openDistraction = nil
        pickupCount = 0
        isPickedUp = false
        detector.start()
        dimScreen()
        phase = .recording
        startWatchdog()
    }

    func finish(store: SessionStore) async {
        guard phase == .recording, let start = startDate else { return }
        phase = .finishing
        watchdogTask?.cancel()
        detector.stop()
        let end = Date()
        let total = end.timeIntervalSince(start)
        closeOpenDistraction()
        // Picking the phone up to end the session shouldn't count against you.
        distractions.removeAll { $0.start > total - 15 }
        restoreScreen()

        let parts = await camera.stopRecording()
        camera.stop()
        let folder = Storage.folder(for: sessionID)
        let result = await VideoTools.assemble(parts: parts, into: folder.appendingPathComponent("raw.mov"))
        for line in result.log { addLog(line) }
        if let url = result.url {
            addLog("Saved \(result.frames) frames (\(VideoTools.fileSizeText(url)))")
        }

        var session = FocusSession(
            id: sessionID,
            title: resolvedTitle(start: start),
            startDate: start,
            endDate: end,
            distractions: distractions,
            frameInterval: frameInterval,
            frameCount: result.frames,
            rawVideoFile: result.url?.lastPathComponent
        )
        session.recordingLog = log
        store.upsert(session)
        session.streakAtEnd = store.streak
        session.coverTemplate = CoverTemplate.lastUsed.rawValue
        session = await RecapBuilder.build(for: session, streak: store.streak)
        store.upsert(session)
        phase = .done(session)
    }

    func teardown() {
        countdownTask?.cancel()
        watchdogTask?.cancel()
        detector.stop()
        if phase == .recording {
            let camera = self.camera
            Task { _ = await camera.stopRecording() }
        }
        camera.stop()
        restoreScreen()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Distractions

    private var elapsed: TimeInterval {
        startDate.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func handlePickup() {
        guard phase == .recording else { return }
        isPickedUp = true
        pickupCount += 1
        openDistractionIfNeeded(.pickup)
        UIScreen.main.brightness = 0.35
    }

    private func handleSettled() {
        guard phase == .recording else { return }
        isPickedUp = false
        if openDistraction?.kind == .pickup { closeOpenDistraction() }
        UIScreen.main.brightness = 0
    }

    func scenePhaseChanged(_ newPhase: ScenePhase) {
        guard phase == .recording else { return }
        switch newPhase {
        case .background:
            openDistractionIfNeeded(.leftApp)
            // The video encoder can't run in the background; close the part cleanly so nothing is lost.
            camera.closeCurrentPart()
            addLog("Left the app")
        case .active:
            if openDistraction?.kind == .leftApp { closeOpenDistraction() }
            UIScreen.main.brightness = isPickedUp ? 0.35 : 0
        default:
            break
        }
    }

    private func openDistractionIfNeeded(_ kind: DistractionInterval.Kind) {
        if openDistraction == nil {
            openDistraction = (elapsed, kind)
        }
    }

    private func closeOpenDistraction() {
        guard let open = openDistraction else { return }
        distractions.append(DistractionInterval(start: open.start, end: elapsed, kind: open.kind))
        openDistraction = nil
    }

    // MARK: Screen

    private func dimScreen() {
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0
    }

    private func restoreScreen() {
        if let saved = savedBrightness {
            UIScreen.main.brightness = saved
            savedBrightness = nil
        }
    }

    private func resolvedTitle(start: Date) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let hour = Calendar.current.component(.hour, from: start)
        let part: String
        switch hour {
        case 5..<12: part = "Morning"
        case 12..<17: part = "Afternoon"
        case 17..<21: part = "Evening"
        default: part = "Late Night"
        }
        return "\(part) Session"
    }
}
