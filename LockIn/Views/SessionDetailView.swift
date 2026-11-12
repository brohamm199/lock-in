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

/// What you can save or share from a session.
enum ExportOption: CaseIterable, Identifiable {
    case statsVideoAndCover, rawVideoAndCover, statsVideo, rawVideo, cover, sticker

    var id: Self { self }

    var title: String {
        switch self {
        case .statsVideoAndCover: return "Video with stats + cover"
        case .rawVideoAndCover: return "Raw video + cover"
        case .statsVideo: return "Video with stats"
        case .rawVideo: return "Raw timelapse"
        case .cover: return "Cover"
        case .sticker: return "Sticker"
        }
    }

    var icon: String {
        switch self {
        case .statsVideoAndCover: return "rectangle.stack.fill"
        case .rawVideoAndCover: return "rectangle.stack"
        case .statsVideo: return "play.rectangle.fill"
        case .rawVideo: return "film"
        case .cover: return "photo.fill"
        case .sticker: return "seal.fill"
        }
    }

    func urls(for session: FocusSession) -> [URL]? {
        switch self {
        case .statsVideoAndCover:
            guard let video = session.shareVideoURL, let cover = session.coverURL else { return nil }
            return [video, cover]
        case .rawVideoAndCover:
            guard let video = session.rawVideoURL, let cover = session.coverURL else { return nil }
            return [video, cover]
        case .statsVideo:
            return session.shareVideoURL.map { [$0] }
        case .rawVideo:
            return session.rawVideoURL.map { [$0] }
        case .cover:
            return session.coverURL.map { [$0] }
        case .sticker:
            return session.stickerURL.map { [$0] }
        }
    }
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
    @State private var pickingStyle = false
    @State private var toast: String?

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
                    ShareButton(title: "Style", icon: "paintpalette.fill") {
                        pickingStyle = true
                    }
                    if session.rawVideoURL != nil {
                        ShareButton(title: "Frame", icon: "photo.on.rectangle") {
                            pickingFrame = true
                        }
                    }
                    ShareButton(title: "Rename", icon: "pencil") {
                        draftTitle = session.title
                        renaming = true
                    }
                }
                .disabled(rebuilding)

                exportButtons(session)
                    .disabled(rebuilding)

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
        .sheet(isPresented: $pickingStyle) {
            CoverStylePicker(session: session, streak: store.streak) { template in
                var updated = session
                updated.coverTemplate = template.rawValue
                CoverTemplate.lastUsed = template
                store.upsert(updated)
                tab = .cover
                rebuild(updated, includeVideo: false)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.15), in: Capsule())
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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

    /// "Save to Photos" and "Share" menus, each offering raw video, stats video, cover, or combinations.
    private func exportButtons(_ session: FocusSession) -> some View {
        let options = ExportOption.allCases.filter { $0.urls(for: session) != nil }

        return HStack(spacing: 10) {
            Menu {
                ForEach(options) { option in
                    Button {
                        save(option.urls(for: session) ?? [])
                    } label: {
                        Label(option.title, systemImage: option.icon)
                    }
                }
            } label: {
                PillLabel(title: "Save to Photos", icon: "square.and.arrow.down", primary: true)
            }
            Menu {
                ForEach(options) { option in
                    Button {
                        shareItem = ShareItem(urls: option.urls(for: session) ?? [])
                    } label: {
                        Label(option.title, systemImage: option.icon)
                    }
                }
            } label: {
                PillLabel(title: "Share", icon: "square.and.arrow.up")
            }
        }
    }

    private func save(_ urls: [URL]) {
        Task {
            let saved = await PhotoSaver.save(urls)
            withAnimation { toast = saved ? "Saved to Photos" : "Couldn't save. Allow Photos access in Settings." }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }
}

struct PillLabel: View {
    let title: String
    let icon: String
    var primary = false

    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(primary ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
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
