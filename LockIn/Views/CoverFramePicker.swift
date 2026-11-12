import AVFoundation
import SwiftUI

/// Scrub through the timelapse and pick the frame used as the cover photo.
struct CoverFramePicker: View {
    let videoURL: URL
    let session: FocusSession
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var duration: Double = 0
    @State private var time: Double = 0
    @State private var preview: UIImage?
    @State private var thumbnails: [UIImage] = []
    @State private var previewGenerator: AVAssetImageGenerator?
    @State private var previewTask: Task<Void, Never>?

    private let thumbnailCount = 8

    /// How far into the real session this frame was captured.
    private var realTime: TimeInterval {
        guard duration > 0 else { return 0 }
        return time / duration * session.duration
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    Color(white: 0.08)
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
                    }
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .frame(maxHeight: .infinity)

                Text("\(Fmt.clock(realTime)) into the session")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

                filmstrip

                Slider(value: $time, in: 0...max(duration, 0.01))
                    .tint(Theme.accent)
                    .disabled(duration == 0)
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Cover frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use frame") {
                        onSave(time)
                        dismiss()
                    }
                    .disabled(duration == 0)
                }
            }
            .task { await load() }
            .onChange(of: time) { _, newTime in
                schedulePreview(at: newTime)
            }
        }
    }

    private var filmstrip: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(thumbnails.indices, id: \.self) { index in
                    Image(uiImage: thumbnails[index])
                        .resizable()
                        .scaledToFill()
                        .frame(width: max(0, geo.size.width / CGFloat(thumbnailCount) - 2), height: 64)
                        .clipped()
                        .onTapGesture {
                            time = duration * (Double(index) + 0.5) / Double(thumbnailCount)
                        }
                }
            }
            .frame(width: geo.size.width, height: 64, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                // Marker showing where the slider is.
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.accent, lineWidth: 3)
                    .frame(width: 10, height: 70)
                    .offset(x: duration > 0 ? CGFloat(time / duration) * (geo.size.width - 10) : 0)
            }
        }
        .frame(height: 70)
    }

    private func load() async {
        let asset = AVURLAsset(url: videoURL)
        guard let loaded = try? await asset.load(.duration) else { return }
        let total = max(CMTimeGetSeconds(loaded) - 0.01, 0)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        previewGenerator = generator

        duration = total
        time = min(session.coverFrameTime ?? total * 0.5, total)
        schedulePreview(at: time)

        let thumbGenerator = AVAssetImageGenerator(asset: asset)
        thumbGenerator.appliesPreferredTrackTransform = true
        thumbGenerator.maximumSize = CGSize(width: 120, height: 214)
        var images: [UIImage] = []
        for i in 0..<thumbnailCount {
            let t = total * (Double(i) + 0.5) / Double(thumbnailCount)
            if let cg = try? await thumbGenerator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                images.append(UIImage(cgImage: cg))
            }
        }
        thumbnails = images
    }

    /// Debounced so dragging the slider doesn't queue up hundreds of frame grabs.
    private func schedulePreview(at seconds: Double) {
        guard let generator = previewGenerator else { return }
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return }
            if let cg = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image,
               !Task.isCancelled {
                preview = UIImage(cgImage: cg)
            }
        }
    }
}
