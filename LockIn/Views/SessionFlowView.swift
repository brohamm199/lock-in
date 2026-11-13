import AVFoundation
import SwiftUI

/// Full-screen flow for one session: setup → countdown → black recording screen → recap.
struct SessionFlowView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = SessionController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch controller.phase {
            case .setup:
                SetupView(controller: controller, camera: controller.camera) { dismiss() }
            case .countdown(let value):
                CountdownView(value: value) { controller.cancelCountdown() }
            case .recording:
                RecordingView(controller: controller) {
                    Task { await controller.finish(store: store) }
                }
            case .finishing:
                ProcessingView()
            case .done(let session):
                NavigationStack {
                    SessionDetailView(sessionID: session.id, isRecap: true)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
        .statusBarHidden(controller.isImmersive)
        .persistentSystemOverlays(controller.isImmersive ? .hidden : .automatic)
        .onAppear { controller.prepare() }
        .onDisappear { controller.teardown() }
        .onChange(of: scenePhase) { _, newPhase in
            controller.scenePhaseChanged(newPhase)
        }
    }
}

// MARK: - Setup

struct SetupView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var camera: TimelapseCamera
    let onClose: () -> Void
    @State private var pinchStart: CGFloat?

    private var speedHint: String {
        let videoSecondsPerHour = 3600 / controller.frameInterval / Double(TimelapseCamera.outputFPS)
        return "1 hour of work → \(Fmt.duration(videoSecondsPerHour)) of video"
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                circleButton("xmark", action: onClose)
                Spacer()
                Text("New session").font(.headline)
                Spacer()
                circleButton("arrow.triangle.2.circlepath.camera") { camera.flip() }
            }

            ZStack {
                if camera.permissionDenied {
                    VStack(spacing: 12) {
                        Image(systemName: "video.slash.fill").font(.largeTitle).foregroundStyle(Theme.accent)
                        Text("Camera access is off").font(.headline)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.card)
                } else {
                    CameraPreview(session: camera.session)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    if pinchStart == nil { pinchStart = camera.displayZoom }
                                    camera.setZoom((pinchStart ?? 1) * value.magnification, animated: false)
                                }
                                .onEnded { _ in pinchStart = nil }
                        )
                        .overlay(alignment: .bottom) {
                            ZoomControl(camera: camera)
                                .padding(.bottom, 12)
                        }
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .frame(maxHeight: .infinity)

            TextField("Session name (optional)", text: $controller.title)
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Picker("Speed", selection: $controller.frameInterval) {
                    Text("Slow-mo").tag(1.0)
                    Text("Normal").tag(2.0)
                    Text("Fast").tag(5.0)
                }
                .pickerStyle(.segmented)
                Text(speedHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Show dim timer while recording", isOn: $controller.showTimer)
                .font(.subheadline)

            Button {
                controller.begin()
            } label: {
                Text("Start")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
            .disabled(camera.permissionDenied)

            Text("Tip: triple-click the side button to turn on Guided Access, so you can't leave the app.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.headline)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.12), in: Circle())
                .foregroundStyle(.white)
        }
    }
}

/// 0.5× / 1× / 2× / 3× buttons, like the Camera app. The active one shows the exact zoom while pinching.
struct ZoomControl: View {
    @ObservedObject var camera: TimelapseCamera

    var body: some View {
        HStack(spacing: 6) {
            ForEach(camera.zoomPresets, id: \.self) { preset in
                let active = activePreset == preset
                Button {
                    camera.setZoom(preset, animated: true)
                } label: {
                    Text(label(for: active ? camera.displayZoom : preset, active: active))
                        .font(.system(size: active ? 13 : 11, weight: .bold))
                        .foregroundStyle(active ? Theme.accent : .white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
            }
        }
        .padding(5)
        .background(Color.black.opacity(0.25), in: Capsule())
    }

    /// The highest preset at or below the current zoom.
    private var activePreset: CGFloat? {
        let atOrBelow = camera.zoomPresets.filter { $0 <= camera.displayZoom + 0.01 }
        return atOrBelow.max() ?? camera.zoomPresets.first
    }

    private func label(for value: CGFloat, active: Bool) -> String {
        let isWhole = abs(value - value.rounded()) < 0.05
        let number = isWhole ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return active ? number + "×" : number
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Countdown

struct CountdownView: View {
    let value: Int
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Put your phone down")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("\(value)")
                .font(.system(size: 140, weight: .black, design: .rounded))
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
                .animation(.default, value: value)
            Text("The screen goes dark and recording starts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onCancel)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 30)
        }
    }
}

// MARK: - Recording (black screen)

struct RecordingView: View {
    @ObservedObject var controller: SessionController
    let onEnd: () -> Void
    @State private var holding = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                if controller.showTimer, let start = controller.startDate {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(Fmt.clock(context.date.timeIntervalSince(start)))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color(white: 0.2))
                    }
                    .padding(.top, 60)
                }
                HStack(spacing: 6) {
                    Circle().fill(Color.red.opacity(0.35)).frame(width: 6, height: 6)
                    FrameCounter(camera: controller.camera)
                    Text("·")
                    Text(controller.pickupCount == 1 ? "1 pickup" : "\(controller.pickupCount) pickups")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color(white: 0.2))

                if controller.cameraStalled {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                        Text("Camera isn't saving frames").font(.headline)
                        Text("Trying to restart it. If this stays,\nhold to end and start a new session.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Color.yellow.opacity(0.8))
                    .padding(.top, 30)
                }

                Spacer()

                if controller.isPickedUp {
                    VStack(spacing: 10) {
                        Image(systemName: "hand.raised.fill").font(.largeTitle)
                        Text("Phone picked up").font(.title3.weight(.bold))
                        Text("Put it back down to keep focusing,\nor hold the button to end the session.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Theme.accent.opacity(0.85))
                    .transition(.opacity)
                }

                Spacer()

                ZStack {
                    Circle().stroke(Color(white: 0.12), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: holding ? 1 : 0)
                        .stroke(Theme.accent.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill")
                        .foregroundStyle(Color(white: 0.25))
                }
                .frame(width: 72, height: 72)
                Text("Hold to end")
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.2))
                    .padding(.bottom, 40)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.3), value: controller.isPickedUp)
        .onLongPressGesture(minimumDuration: 2, maximumDistance: 60) {
            onEnd()
        } onPressingChanged: { pressing in
            withAnimation(pressing ? .linear(duration: 2) : .easeOut(duration: 0.2)) {
                holding = pressing
            }
        }
    }
}

/// Live "123 frames" readout, so you can see the timelapse is actually saving.
struct FrameCounter: View {
    @ObservedObject var camera: TimelapseCamera

    var body: some View {
        Text(camera.framesCaptured == 1 ? "1 frame" : "\(camera.framesCaptured) frames")
    }
}

struct ProcessingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text("Building your recap…")
                .font(.headline)
            Text("Saving the timelapse, then rendering the cover and video.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
