import Photos

enum PhotoSaver {
    /// Saves videos (.mp4/.mov) and images to the Photos library. Only asks for "add photos" access.
    static func save(_ urls: [URL]) async -> Bool {
        guard !urls.isEmpty else { return false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    if ["mp4", "mov"].contains(url.pathExtension.lowercased()) {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }
}
