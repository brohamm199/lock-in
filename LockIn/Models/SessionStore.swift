import Foundation

struct DayTotal: Identifiable {
    let date: Date
    let seconds: TimeInterval
    var id: Date { date }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [FocusSession] = []

    private var indexURL: URL { Storage.documents.appendingPathComponent("sessions.json") }

    init() {
        load()
    }

    func session(id: UUID) -> FocusSession? {
        sessions.first { $0.id == id }
    }

    func upsert(_ session: FocusSession) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.startDate > $1.startDate }
        save()
    }

    func delete(_ session: FocusSession) {
        sessions.removeAll { $0.id == session.id }
        try? FileManager.default.removeItem(at: Storage.folder(for: session.id))
        save()
    }

    /// Consecutive days (ending today or yesterday) with at least one session.
    var streak: Int {
        let cal = Calendar.current
        let days = Set(sessions.map { cal.startOfDay(for: $0.startDate) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    func lastSevenDays() -> [DayTotal] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset -> DayTotal? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let total = sessions
                .filter { cal.isDate($0.startDate, inSameDayAs: day) }
                .reduce(0) { $0 + $1.focusedTime }
            return DayTotal(date: day, seconds: total)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([FocusSession].self, from: data) else { return }
        sessions = decoded.sorted { $0.startDate > $1.startDate }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
