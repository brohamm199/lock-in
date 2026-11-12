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

    let camera = TimelapseCamera()
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
        let url = Storage.folder(for: sessionID).appendingPathComponent("raw.mp4")
        camera.startRecording(to: url, interval: frameInterval)
        startDate = Date()
        distractions = []
        openDistraction = nil
        pickupCount = 0
        isPickedUp = false
        detector.start()
        dimScreen()
        phase = .recording
    }

    func finish(store: SessionStore) async {
        guard phase == .recording, let start = startDate else { return }
        phase = .finishing
        detector.stop()
        let end = Date()
        let total = end.timeIntervalSince(start)
        closeOpenDistraction()
        // Picking the phone up to end the session shouldn't count against you.
        distractions.removeAll { $0.start > total - 15 }
        restoreScreen()

        let result = await camera.stopRecording()
        camera.stop()

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
        store.upsert(session)
        session.streakAtEnd = store.streak
        session.coverTemplate = CoverTemplate.lastUsed.rawValue
        session = await RecapBuilder.build(for: session, streak: store.streak)
        store.upsert(session)
        phase = .done(session)
    }

    func teardown() {
        countdownTask?.cancel()
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
