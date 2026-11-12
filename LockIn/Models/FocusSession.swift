import Foundation

/// A stretch of a session where you weren't focused (picked the phone up, or left the app).
struct DistractionInterval: Codable, Hashable {
    enum Kind: String, Codable {
        case pickup
        case leftApp
    }

    /// Seconds from the start of the session.
    var start: TimeInterval
    var end: TimeInterval
    var kind: Kind

    var length: TimeInterval { max(0, end - start) }
}

struct FocusSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var startDate: Date
    var endDate: Date
    var distractions: [DistractionInterval] = []
    /// Real-world seconds between timelapse frames.
    var frameInterval: TimeInterval
    var frameCount: Int = 0
    var rawVideoFile: String?
    var shareVideoFile: String?
    var coverFile: String?
    var stickerFile: String?
    var thumbFile: String?
    /// Position in the timelapse (seconds) to use as the cover photo. nil = middle of the video.
    var coverFrameTime: Double?
    /// Streak at the moment the session ended, so rebuilding a recap later shows the same number.
    var streakAtEnd: Int?

    var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }
    var distractedTime: TimeInterval { min(duration, distractions.reduce(0) { $0 + $1.length }) }
    var focusedTime: TimeInterval { max(0, duration - distractedTime) }
    var focusScore: Int { duration > 0 ? Int((focusedTime / duration * 100).rounded()) : 100 }
    var pickups: Int { distractions.filter { $0.kind == .pickup }.count }
    var leftAppCount: Int { distractions.filter { $0.kind == .leftApp }.count }
    var timelapseLength: TimeInterval { Double(frameCount) / Double(TimelapseCamera.outputFPS) }

    var rawVideoURL: URL? { Storage.existingFile(rawVideoFile, for: id) }
    var shareVideoURL: URL? { Storage.existingFile(shareVideoFile, for: id) }
    var coverURL: URL? { Storage.existingFile(coverFile, for: id) }
    var stickerURL: URL? { Storage.existingFile(stickerFile, for: id) }
    var thumbURL: URL? { Storage.existingFile(thumbFile, for: id) }

    /// Fraction of each time slice spent focused (1 = fully focused). Used for the "focus profile" graph.
    func focusProfile(buckets: Int) -> [Double] {
        guard duration > 0, buckets > 0 else { return [1, 1] }
        let size = duration / Double(buckets)
        let values = (0..<buckets).map { i -> Double in
            let s = Double(i) * size
            let e = s + size
            let lost = distractions.reduce(0.0) { acc, d in acc + max(0, min(e, d.end) - max(s, d.start)) }
            return max(0, min(1, 1 - lost / size))
        }
        return values.count > 1 ? values : values + values
    }
}

enum Storage {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func folder(for id: UUID) -> URL {
        let url = documents.appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func existingFile(_ name: String?, for id: UUID) -> URL? {
        guard let name else { return nil }
        let url = folder(for: id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
