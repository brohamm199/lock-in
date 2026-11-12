import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var showingSession = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WeekCard(days: store.lastSevenDays(), streak: store.streak)

                    Button {
                        showingSession = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "record.circle.fill")
                            Text("Enter the tunnel")
                        }
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                    }

                    if store.sessions.isEmpty {
                        Text("No sessions yet. Prop your phone up, hit Enter the tunnel, and get to work.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        Text("Sessions")
                            .font(.title3.weight(.bold))
                        LazyVStack(spacing: 12) {
                            ForEach(store.sessions) { session in
                                NavigationLink(value: session.id) {
                                    SessionRow(session: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Tunnel")
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionID: id)
            }
            .fullScreenCover(isPresented: $showingSession) {
                SessionFlowView()
                    .environmentObject(store)
            }
        }
    }
}

struct WeekCard: View {
    let days: [DayTotal]
    let streak: Int

    var body: some View {
        let total = days.reduce(0) { $0 + $1.seconds }
        let maxSeconds = max(days.map(\.seconds).max() ?? 0, 1)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FOCUSED THIS WEEK")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(Fmt.duration(total))
                        .font(.system(size: 34, weight: .bold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("STREAK")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Label("\(streak)", systemImage: "flame.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { day in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(day.seconds > 0 ? Theme.accent : Color(white: 0.2))
                            .frame(height: max(4, 70 * day.seconds / maxSeconds))
                        Text(Fmt.weekdayLetter.string(from: day.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92, alignment: .bottom)
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct SessionRow: View {
    let session: FocusSession

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let url = session.thumbURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(white: 0.16)
                        Image(systemName: "timer").foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(width: 54, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(Fmt.dateTime.string(from: session.startDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    mini("Time", Fmt.duration(session.duration))
                    mini("Focus", "\(session.focusScore)%")
                    mini("Pickups", "\(session.pickups)")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func mini(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
        }
    }
}
