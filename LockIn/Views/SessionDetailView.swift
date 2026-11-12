import AVKit
import SwiftUI

enum RecapTab: String, CaseIterable, Identifiable {
    case cover = "Cover"
    case video = "Video"
    case sticker = "Sticker"

    var id: String { rawValue }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct SessionDetailView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    var isRecap = false

    @State private var tab: RecapTab = .cover
    @State private var shareItem: ShareItem?
    @State private var player: AVPlayer?
    @State private var rebuilding = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var pickingFrame = false

    var body: some View {
        Group {
            if let session = store.session(id: sessionID) {
                content(session)
            } else {
                ContentUnavailableView("Session deleted", systemImage: "trash")
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func content(_ session: FocusSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("View", selection: $tab) {
                    ForEach(RecapTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                preview(session)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    ShareButton(title: "Rename", icon: "pencil") {
                        draftTitle = session.title
                        renaming = true
                    }
                    if session.rawVideoURL != nil {
                        ShareButton(title: "Cover frame", icon: "photo.on.rectangle") {
                            pickingFrame = true
                        }
                    }
                }
                .disabled(rebuilding)

                shareButtons(session)

                StatsGrid(session: session)

                if session.coverFile == nil || (session.rawVideoFile != nil && session.shareVideoFile == nil) {
                    Button {
                        rebuild(session, includeVideo: true)
                    } label: {
                        HStack {
                            if rebuilding { ProgressView() }
                            Text(rebuilding ? "Rebuilding…" : "Rebuild recap")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(rebuilding)
                }
            }
            .padding()
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isRecap {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player?.pause()
                store.delete(session)
                dismiss()
            }
        } message: {
            Text("The timelapse and cover will be removed from this phone.")
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.urls)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $pickingFrame) {
            if let url = session.rawVideoURL {
                CoverFramePicker(videoURL: url, session: session) { time in
                    var updated = session
                    updated.coverFrameTime = time
                    store.upsert(updated)
                    tab = .cover
                    rebuild(updated, includeVideo: false)
                }
            }
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Session name", text: $draftTitle)
            Button("Save") {
                let name = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != session.title else { return }
                var updated = session
                updated.title = name
                store.upsert(updated)
                // The name is on the cover, sticker and video, so redo all three.
                rebuild(updated, includeVideo: true)
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay {
            if rebuilding {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(Theme.accent)
                    Text("Updating your recap…").font(.subheadline.weight(.semibold))
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .onChange(of: tab) { _, newTab in
            if newTab != .video { player?.pause() }
        }
    }

    private func rebuild(_ session: FocusSession, includeVideo: Bool) {
        guard !rebuilding else { return }
        rebuilding = true
        if includeVideo {
            // Release the old file before it gets overwritten.
            player?.pause()
            player = nil
        }
        Task {
            let updated = await RecapBuilder.build(for: session, streak: store.streak, includeVideo: includeVideo)
            store.upsert(updated)
            if includeVideo, let url = updated.shareVideoURL ?? updated.rawVideoURL {
                player = AVPlayer(url: url)
            }
            rebuilding = false
        }
    }

    @ViewBuilder
    private func preview(_ session: FocusSession) -> some View {
        switch tab {
        case .cover:
            if let url = session.coverURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                placeholder("No cover yet")
            }
        case .video:
            if let url = session.shareVideoURL ?? session.rawVideoURL {
                VideoPlayer(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onAppear {
                        if player == nil { player = AVPlayer(url: url) }
                        player?.seek(to: .zero)
                        player?.play()
                    }
                    .onDisappear { player?.pause() }
            } else {
                placeholder("No video. The session was too short to capture any frames.")
            }
        case .sticker:
            if let url = session.stickerURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(colors: [Color(white: 0.3), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
            } else {
                placeholder("No sticker yet")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, minHeight: 240)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func shareButtons(_ session: FocusSession) -> some View {
        let video = session.shareVideoURL ?? session.rawVideoURL
        let cover = session.coverURL
        let sticker = session.stickerURL

        return VStack(spacing: 10) {
            if let video, let cover {
                ShareButton(title: "Share video + cover", icon: "square.and.arrow.up", primary: true) {
                    shareItem = ShareItem(urls: [video, cover])
                }
            }
            HStack(spacing: 10) {
                if let video {
                    ShareButton(title: "Video", icon: "play.rectangle.fill") { shareItem = ShareItem(urls: [video]) }
                }
                if let cover {
                    ShareButton(title: "Cover", icon: "photo.fill") { shareItem = ShareItem(urls: [cover]) }
                }
                if let sticker {
                    ShareButton(title: "Sticker", icon: "seal.fill") { shareItem = ShareItem(urls: [sticker]) }
                }
            }
        }
    }
}

struct ShareButton: View {
    let title: String
    let icon: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(primary ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
    }
}

struct StatsGrid: View {
    let session: FocusSession

    var body: some View {
        let items: [(String, String)] = [
            ("Time", Fmt.duration(session.duration)),
            ("Focused", Fmt.duration(session.focusedTime)),
            ("Focus", "\(session.focusScore)%"),
            ("Pickups", "\(session.pickups)"),
            ("Left app", "\(session.leftAppCount)"),
            ("Timelapse", Fmt.duration(session.timelapseLength)),
        ]

        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 16) {
                ForEach(items.indices, id: \.self) { index in
                    StatBlock(label: items[index].0, value: items[index].1, valueSize: 22)
                }
            }
            Text("FOCUS PROFILE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            FocusProfileView(values: session.focusProfile(buckets: 40))
                .frame(height: 60)
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
