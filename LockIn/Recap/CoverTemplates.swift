import SwiftUI

// MARK: - Template list

enum CoverTemplate: String, CaseIterable, Identifiable, Codable {
    case glass, glassTop, classic, minimal, receipt, poster, filmStrip, polaroid, magazine, split
    case terminal, scoreboard, duotone, ticket, boardingPass, badge, bigType, calendar, sunset, tiles

    var id: String { rawValue }

    var name: String {
        switch self {
        case .glass: return "Glass"
        case .glassTop: return "Glass Top"
        case .classic: return "Classic"
        case .minimal: return "Minimal"
        case .receipt: return "Receipt"
        case .poster: return "Poster"
        case .filmStrip: return "Film Strip"
        case .polaroid: return "Polaroid"
        case .magazine: return "Magazine"
        case .split: return "Split"
        case .terminal: return "Terminal"
        case .scoreboard: return "Scoreboard"
        case .duotone: return "Duotone"
        case .ticket: return "Ticket"
        case .boardingPass: return "Boarding Pass"
        case .badge: return "Badge"
        case .bigType: return "Big Type"
        case .calendar: return "Calendar"
        case .sunset: return "Sunset"
        case .tiles: return "Tiles"
        }
    }

    /// New sessions start with whatever style you picked last.
    static var lastUsed: CoverTemplate {
        get { UserDefaults.standard.string(forKey: "lastCoverTemplate").flatMap { CoverTemplate(rawValue: $0) } ?? .glass }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lastCoverTemplate") }
    }
}

enum CoverSize {
    static let width: CGFloat = 360
    static let height: CGFloat = 640
}

struct CoverContext {
    let session: FocusSession
    let photo: UIImage?
    let blurred: UIImage?
    /// A few frames from across the timelapse (for Film Strip).
    let frames: [UIImage]
    let streak: Int
    let videoSize: CGSize

    var title: String { session.title }
    var duration: String { Fmt.duration(session.duration) }
    var clock: String { Fmt.clock(session.duration) }
    var focused: String { Fmt.duration(session.focusedTime) }
    var focusedClock: String { Fmt.clock(session.focusedTime) }
    var focus: String { "\(session.focusScore)%" }
    var pickups: String { "\(session.pickups)" }
    var date: String { Fmt.dateTime.string(from: session.startDate) }
    var shortDate: String { Fmt.shortDate.string(from: session.startDate) }
    var startTime: String { Fmt.timeOnly.string(from: session.startDate) }
    var bigParts: [String] { Fmt.bigParts(session.duration) }
    var profile: [Double] { session.focusProfile(buckets: 40) }
    var serial: String { String(session.id.uuidString.prefix(6)) }
}

// MARK: - Entry point

/// A 360×640 pt cover (rendered at 3× = 1080×1920).
struct CoverView: View {
    let template: CoverTemplate
    let context: CoverContext

    var body: some View {
        content
            .frame(width: CoverSize.width, height: CoverSize.height)
            .clipped()
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch template {
        case .glass: GlassCover(c: context, top: false)
        case .glassTop: GlassCover(c: context, top: true)
        case .classic: ClassicCover(c: context)
        case .minimal: MinimalCover(c: context)
        case .receipt: ReceiptCover(c: context)
        case .poster: PosterCover(c: context)
        case .filmStrip: FilmStripCover(c: context)
        case .polaroid: PolaroidCover(c: context)
        case .magazine: MagazineCover(c: context)
        case .split: SplitCover(c: context)
        case .terminal: TerminalCover(c: context)
        case .scoreboard: ScoreboardCover(c: context)
        case .duotone: DuotoneCover(c: context)
        case .ticket: TicketCover(c: context)
        case .boardingPass: BoardingPassCover(c: context)
        case .badge: BadgeCover(c: context)
        case .bigType: BigTypeCover(c: context)
        case .calendar: CalendarCover(c: context)
        case .sunset: SunsetCover(c: context)
        case .tiles: TilesCover(c: context)
        }
    }
}

// MARK: - Shared pieces

struct CoverPhoto: View {
    let image: UIImage?
    var width: CGFloat = CoverSize.width
    var height: CGFloat = CoverSize.height

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.06)
                    RadialGradient(colors: [Theme.accent.opacity(0.5), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

struct StreakPill: View {
    let streak: Int

    var body: some View {
        Label("\(streak)", systemImage: "flame.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.18), in: Capsule())
    }
}

struct DashedRule: View {
    var color: Color = .black.opacity(0.5)

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .frame(height: 1)
    }
}

struct Barcode: View {
    let seed: String
    var color: Color = .black
    var bars = 36

    var body: some View {
        let widths = seed.unicodeScalars.prefix(bars).map { CGFloat($0.value % 3) + 1 }
        HStack(spacing: 1.5) {
            ForEach(widths.indices, id: \.self) { index in
                Rectangle()
                    .fill(index % 2 == 0 ? color : Color.clear)
                    .frame(width: widths[index])
            }
        }
    }
}

private func caps(_ text: String, size: CGFloat = 10, tracking: CGFloat = 1.5) -> Text {
    Text(text.uppercased())
        .font(.system(size: size, weight: .bold))
        .tracking(tracking)
}

// MARK: - 1, 2. Glass / Glass Top

struct GlassCover: View {
    let c: CoverContext
    let top: Bool

    private let inset: CGFloat = 14
    private let cardHeight: CGFloat = 236
    private var cardY: CGFloat { top ? 64 : CoverSize.height - inset - cardHeight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverPhoto(image: c.photo)
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: CoverSize.width, height: 120)
            HStack(alignment: .firstTextBaseline) {
                BrandMark(size: 14)
                Spacer()
                if c.streak > 0 { StreakPill(streak: c.streak) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .frame(width: CoverSize.width)

            card
                .frame(width: CoverSize.width - inset * 2, height: cardHeight)
                .offset(x: inset, y: cardY)
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ZStack(alignment: .topLeading) {
            // Frosted glass: the blurred photo, lined up with the sharp one behind it.
            CoverPhoto(image: c.blurred ?? c.photo)
                .offset(x: -inset, y: -cardY)
                .frame(width: CoverSize.width - inset * 2, height: cardHeight, alignment: .topLeading)
                .clipped()
            Color.black.opacity(0.22)
            Color.white.opacity(0.10)

            VStack(alignment: .leading, spacing: 0) {
                Text(c.title)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(c.date)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 2)
                HStack(alignment: .top) {
                    StatBlock(label: "Time", value: c.duration, valueSize: 24)
                    Spacer()
                    StatBlock(label: "Focus", value: c.focus, valueSize: 24)
                    Spacer()
                    StatBlock(label: "Pickups", value: c.pickups, valueSize: 24)
                }
                .padding(.top, 16)
                FocusProfileView(values: c.profile)
                    .frame(height: 46)
                    .padding(.top, 14)
                Spacer(minLength: 0)
                Text("\(c.focused) focused")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(18)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75))
    }
}

// MARK: - 3. Classic

struct ClassicCover: View {
    let c: CoverContext

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverPhoto(image: c.photo)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.4),
                    .init(color: .black.opacity(0.85), location: 0.7),
                    .init(color: .black.opacity(0.95), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    BrandMark(size: 14)
                    Spacer()
                    Text(c.date)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Text(c.title)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.bottom, 18)
                HStack(alignment: .top, spacing: 26) {
                    StatBlock(label: "Time", value: c.duration)
                    StatBlock(label: "Focus", value: c.focus)
                    StatBlock(label: "Pickups", value: c.pickups)
                }
                FocusProfileView(values: c.profile)
                    .frame(height: 64)
                    .padding(.top, 20)
            }
            .padding(24)
            .frame(width: CoverSize.width, height: CoverSize.height)
        }
    }
}

// MARK: - 4. Minimal

struct MinimalCover: View {
    let c: CoverContext

    var body: some View {
        ZStack {
            CoverPhoto(image: c.photo)
            Color.black.opacity(0.55)
            VStack(spacing: 0) {
                BrandMark(size: 12, color: .white.opacity(0.85))
                    .padding(.top, 34)
                Spacer()
                Text(c.clock)
                    .font(.system(size: 66, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                caps("\(c.focus) focus  ·  \(c.pickups) pickups", size: 11, tracking: 2)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 8)
                Spacer()
                FocusProfileView(values: c.profile, color: .white, lineWidth: 1.2)
                    .frame(width: 220, height: 34)
                Text(c.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 18)
                Text(c.date)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 3)
                    .padding(.bottom, 36)
            }
            .frame(width: CoverSize.width, height: CoverSize.height)
        }
    }
}

// MARK: - 5. Receipt

struct ReceiptCover: View {
    let c: CoverContext
    private let ink = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let paper = Color(red: 0.96, green: 0.95, blue: 0.92)

    var body: some View {
        ZStack(alignment: .bottom) {
            CoverPhoto(image: c.photo)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(spacing: 6) {
                Text("TUNNEL")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .tracking(5)
                Text("FOCUS RECEIPT  #\(c.serial)")
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.6)
                DashedRule(color: ink.opacity(0.5)).padding(.vertical, 4)
                row(c.title.uppercased(), c.shortDate.uppercased())
                row("STARTED", c.startTime)
                row("FOCUSED", c.focusedClock)
                row("PICKUPS", "x\(c.pickups)")
                row("LEFT APP", "x\(c.session.leftAppCount)")
                row("FOCUS SCORE", c.focus)
                DashedRule(color: ink.opacity(0.5)).padding(.vertical, 4)
                row("TOTAL", c.clock)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                DashedRule(color: ink.opacity(0.5)).padding(.vertical, 4)
                Barcode(seed: c.session.id.uuidString, color: ink)
                    .frame(height: 34)
                Text("THANK YOU FOR FOCUSING")
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.6)
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(ink)
            .padding(18)
            .frame(width: 272)
            .background(paper)
            .rotationEffect(.degrees(-2))
            .padding(.bottom, 44)
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }

    private func row(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left).lineLimit(1)
            Spacer(minLength: 8)
            Text(right)
        }
    }
}

// MARK: - 6. Poster

struct PosterCover: View {
    let c: CoverContext
    private let ink = Color(red: 0.10, green: 0.04, blue: 0.01)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.accent
            CoverPhoto(image: c.photo, width: 176, height: 250)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 88, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 88))
                .offset(x: 160, y: 44)
            Text("IN THE\nTUNNEL.")
                .font(.system(size: 18, weight: .black))
                .tracking(1)
                .lineSpacing(2)
                .foregroundStyle(ink)
                .offset(x: 24, y: 48)
            VStack(alignment: .leading, spacing: -18) {
                ForEach(c.bigParts, id: \.self) { part in
                    Text(part)
                        .font(.system(size: 108, weight: .black))
                        .tracking(-5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .foregroundStyle(ink)
            .frame(width: 320, alignment: .leading)
            .offset(x: 20, y: 300)
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(ink).frame(height: 2)
                HStack {
                    Text(c.title).fontWeight(.bold).lineLimit(1)
                    Spacer()
                    Text("\(c.focus) focus")
                }
                HStack {
                    Text(c.shortDate)
                    Spacer()
                    Text("\(c.pickups) pickups")
                }
                .opacity(0.75)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ink)
            .frame(width: 312)
            .offset(x: 24, y: 548)
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }
}

// MARK: - 7. Film Strip

struct FilmStripCover: View {
    let c: CoverContext

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.04)
            BrandMark(size: 13)
                .offset(x: 22, y: 30)
            filmStrip
                .offset(y: 84)
            VStack(alignment: .leading, spacing: 6) {
                caps("\(c.title)  ·  \(c.shortDate)", size: 10)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text(c.clock)
                    .font(.system(size: 56, weight: .light, design: .monospaced))
                    .foregroundStyle(.white)
                HStack(spacing: 18) {
                    Text("\(c.focus) focus")
                    Text("\(c.pickups) pickups")
                    if c.streak > 0 { Text("\(c.streak)-day streak") }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                FocusProfileView(values: c.profile)
                    .frame(height: 56)
                    .padding(.top, 14)
            }
            .frame(width: 316, alignment: .leading)
            .offset(x: 22, y: 362)
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }

    private var filmStrip: some View {
        let images: [UIImage?] = c.frames.isEmpty ? [c.photo, c.photo, c.photo] : c.frames.map { Optional($0) }
        return VStack(spacing: 6) {
            sprockets
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    CoverPhoto(image: index < images.count ? images[index] : c.photo, width: 110, height: 196)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            sprockets
        }
        .padding(.vertical, 8)
        .frame(width: CoverSize.width)
        .background(Color(white: 0.14))
    }

    private var sprockets: some View {
        HStack(spacing: 9) {
            ForEach(0..<18, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(white: 0.04))
                    .frame(width: 10, height: 7)
            }
        }
    }
}

// MARK: - 8. Polaroid

struct PolaroidCover: View {
    let c: CoverContext

    var body: some View {
        ZStack {
            CoverPhoto(image: c.blurred ?? c.photo)
            Color.black.opacity(0.35)
            VStack(spacing: 0) {
                CoverPhoto(image: c.photo, width: 264, height: 300)
                VStack(alignment: .leading, spacing: 5) {
                    Text(c.title)
                        .font(.system(size: 24, design: .serif))
                        .italic()
                        .foregroundStyle(Color(white: 0.15))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("\(c.duration) · \(c.focus) focus · \(c.pickups) pickups")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 0.4))
                }
                .frame(width: 264, alignment: .leading)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .background(Color(red: 0.98, green: 0.97, blue: 0.95))
            .rotationEffect(.degrees(-3))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            VStack {
                HStack(alignment: .firstTextBaseline) {
                    BrandMark(size: 13)
                    Spacer()
                    Text(c.date)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(22)
                Spacer()
            }
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }
}

// MARK: - 9. Magazine

struct MagazineCover: View {
    let c: CoverContext

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverPhoto(image: c.photo)
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Text("TUNNEL")
                    .font(.system(size: 92, weight: .black, design: .serif))
                    .tracking(-3)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack {
                    caps("The focus issue")
                    Spacer()
                    caps(c.shortDate)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, -6)
                Spacer().frame(height: 40)
                coverLine(c.duration, "of deep work")
                coverLine(c.focus, "focus score").padding(.top, 18)
                coverLine(c.pickups, c.session.pickups == 1 ? "pickup. that's it." : "pickups. that's it.").padding(.top, 18)
                Spacer()
                Text(c.title)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .italic()
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 60, height: 4)
                    .padding(.top, 10)
            }
            .padding(22)
            .frame(width: CoverSize.width, height: CoverSize.height, alignment: .topLeading)
        }
    }

    private func coverLine(_ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(big)
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Theme.accent)
            caps(small, size: 11)
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
    }
}

// MARK: - 10. Split

struct SplitCover: View {
    let c: CoverContext

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CoverPhoto(image: c.photo, width: CoverSize.width, height: 352)
                BrandMark(size: 13).padding(20)
            }
            VStack(alignment: .leading, spacing: 0) {
                caps(c.date, size: 10)
                    .foregroundStyle(.white.opacity(0.5))
                Text(c.title)
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 4)
                Grid(alignment: .leading, horizontalSpacing: 34, verticalSpacing: 14) {
                    GridRow {
                        StatBlock(label: "Time", value: c.duration, valueSize: 28)
                        StatBlock(label: "Focus", value: c.focus, valueSize: 28)
                    }
                    GridRow {
                        StatBlock(label: "Pickups", value: c.pickups, valueSize: 28)
                        StatBlock(label: "Focused", value: c.focused, valueSize: 28)
                    }
                }
                .padding(.top, 16)
                Spacer(minLength: 0)
                FocusProfileView(values: c.profile)
                    .frame(height: 36)
            }
            .padding(22)
            .frame(width: CoverSize.width, height: CoverSize.height - 352, alignment: .topLeading)
            .background(Color(white: 0.05))
        }
    }
}

// MARK: - 11. Terminal

struct TerminalCover: View {
    let c: CoverContext
    private let green = Color(red: 0.35, green: 1.0, blue: 0.55)

    private var scoreBar: String {
        let filled = max(0, min(10, c.session.focusScore / 10))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.02, green: 0.05, blue: 0.03)
            CoverPhoto(image: c.photo).opacity(0.12)
            VStack(alignment: .leading, spacing: 8) {
                Text("tunnel@iphone ~ % focus --end")
                    .foregroundStyle(green.opacity(0.7))
                line("session", "\"\(c.title)\"")
                line("started", c.date)
                line("elapsed", c.clock)
                line("focused", c.focusedClock)
                line("score", "\(c.focus) \(scoreBar)")
                line("pickups", c.pickups)
                line("status", c.session.focusScore >= 80 ? "LOCKED IN ✓" : "GOT DISTRACTED")
                FocusProfileView(values: c.profile, color: green, lineWidth: 1.5)
                    .frame(height: 64)
                    .padding(.vertical, 14)
                if c.streak > 0 {
                    Text("streak: \(c.streak) day\(c.streak == 1 ? "" : "s")")
                        .foregroundStyle(green.opacity(0.8))
                }
                Text("tunnel@iphone ~ % █")
                    .foregroundStyle(green.opacity(0.7))
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(green)
            .padding(.horizontal, 24)
            .padding(.top, 150)
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }

    private func line(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(">").opacity(0.6)
            Text(key.padding(toLength: 8, withPad: " ", startingAt: 0))
            Text(value)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

// MARK: - 12. Scoreboard

struct ScoreboardCover: View {
    let c: CoverContext

    var body: some View {
        ZStack {
            CoverPhoto(image: c.photo)
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 18) {
                caps("Tunnel · scoreboard", size: 11, tracking: 3)
                    .foregroundStyle(Theme.accent)
                scoreRow("Time", c.clock)
                scoreRow("Focus %", "\(c.session.focusScore)")
                scoreRow("Pickups", String(format: "%02d", c.session.pickups))
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title)
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(c.date)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 4)
            }
            .frame(width: 270, alignment: .leading)
            .padding(22)
            .background(Color(white: 0.07).opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(white: 0.28), lineWidth: 2))
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }

    private func scoreRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caps(label, size: 10, tracking: 2)
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 4) {
                ForEach(Array(value.enumerated()), id: \.offset) { _, character in
                    if character == ":" {
                        Text(":")
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    } else {
                        Text(String(character))
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 46)
                            .background(Color.black, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }
}

// MARK: - 13. Duotone

struct DuotoneCover: View {
    let c: CoverContext

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverPhoto(image: c.photo)
                .grayscale(1)
                .contrast(1.25)
                .colorMultiply(Theme.accent)
            LinearGradient(colors: [.clear, Color(red: 0.25, green: 0.06, blue: 0).opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                BrandMark(size: 13, color: .white)
                Spacer()
                caps(c.title, size: 12, tracking: 2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(c.duration)
                    .font(.system(size: 72, weight: .black))
                    .tracking(-2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 22) {
                    StatBlock(label: "Focus", value: c.focus, valueSize: 22)
                    StatBlock(label: "Pickups", value: c.pickups, valueSize: 22)
                    StatBlock(label: "Date", value: c.shortDate, valueSize: 22)
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(width: CoverSize.width, height: CoverSize.height, alignment: .leading)
        }
    }
}

// MARK: - 14. Ticket

struct TicketCover: View {
    let c: CoverContext
    private let ink = Color(red: 0.12, green: 0.10, blue: 0.09)
    private let cream = Color(red: 0.98, green: 0.95, blue: 0.89)

    var body: some View {
        ZStack {
            CoverPhoto(image: c.blurred ?? c.photo)
            Color.black.opacity(0.3)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        caps("Admit one", size: 11, tracking: 3).foregroundStyle(Theme.accent)
                        Spacer()
                        Text("No. \(c.serial)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(ink.opacity(0.6))
                    }
                    Text("DEEP WORK")
                        .font(.system(size: 36, weight: .black))
                        .foregroundStyle(ink)
                    Text(c.title)
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .italic()
                        .foregroundStyle(ink.opacity(0.8))
                        .lineLimit(1)
                    HStack(spacing: 22) {
                        field("Date", c.shortDate, ink)
                        field("Start", c.startTime, ink)
                        field("Length", c.duration, ink)
                    }
                    .padding(.top, 6)
                }
                .padding(20)
                .frame(width: 290, alignment: .leading)
                .background(cream)

                ZStack {
                    cream
                    DashedRule(color: ink.opacity(0.4)).padding(.horizontal, 14)
                }
                .frame(width: 290, height: 12)

                HStack(alignment: .bottom) {
                    field("Focus", c.focus, .white)
                    field("Pickups", c.pickups, .white)
                    Spacer()
                    Barcode(seed: c.session.id.uuidString, color: .white, bars: 20)
                        .frame(height: 34)
                }
                .padding(20)
                .frame(width: 290)
                .background(Theme.accent)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            .rotationEffect(.degrees(4))
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }

    private func field(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            caps(label, size: 9).opacity(0.6)
            Text(value).font(.system(size: 15, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

// MARK: - 15. Boarding Pass

struct BoardingPassCover: View {
    let c: CoverContext

    var body: some View {
        ZStack {
            CoverPhoto(image: c.blurred ?? c.photo)
            Color.black.opacity(0.35)
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "airplane")
                    caps("Tunnel Air", size: 11, tracking: 2)
                    Spacer()
                    caps("Boarding pass", size: 11, tracking: 2)
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(Theme.accent)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center) {
                        airport("DST", "Distracted", alignment: .leading)
                        Spacer()
                        Image(systemName: "airplane")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        airport("FOC", "Focused", alignment: .trailing)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                        GridRow { field("Passenger", "You"); field("Flight", c.title) }
                        GridRow { field("Date", c.shortDate); field("Departs", c.startTime) }
                        GridRow { field("Flight time", c.duration); field("Focus", c.focus) }
                        GridRow { field("Turbulence", "\(c.pickups) pickups"); field("Streak", "\(c.streak) days") }
                    }
                    DashedRule(color: .black.opacity(0.3))
                    Barcode(seed: c.session.id.uuidString, color: .black)
                        .frame(height: 40)
                        .frame(maxWidth: .infinity)
                }
                .padding(18)
                .background(Color.white)
            }
            .frame(width: 300)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }

    private func airport(_ code: String, _ name: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(code)
                .font(.system(size: 40, weight: .black))
                .foregroundStyle(.black)
            caps(name, size: 9)
                .foregroundStyle(Color(white: 0.45))
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            caps(label, size: 9).foregroundStyle(Color(white: 0.5))
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .lineLimit(1)
        }
    }
}

// MARK: - 16. Badge

struct BadgeCover: View {
    let c: CoverContext

    var body: some View {
        ZStack {
            CoverPhoto(image: c.photo)
            Color.black.opacity(0.25)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    BrandMark(size: 13)
                    Spacer()
                    Text(c.date)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(22)
                Spacer()
                ZStack {
                    Circle().fill(Theme.accent)
                    Circle().strokeBorder(Color.white, lineWidth: 4).padding(10)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                        .padding(22)
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { _ in
                                Image(systemName: "star.fill").font(.system(size: 10))
                            }
                        }
                        caps("Focus session", size: 10, tracking: 2)
                        Text(c.duration)
                            .font(.system(size: 44, weight: .black))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("\(c.focus) FOCUS")
                            .font(.system(size: 13, weight: .heavy))
                        Text("\(c.pickups) PICKUPS")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(40)
                }
                .frame(width: 250, height: 250)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .rotationEffect(.degrees(-8))
                Spacer()
                Text(c.title)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 44)
            }
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }
}

// MARK: - 17. Big Type

struct BigTypeCover: View {
    let c: CoverContext

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverPhoto(image: c.photo)
            Color.black.opacity(0.4)
            VStack(alignment: .leading, spacing: 0) {
                BrandMark(size: 13, color: .white)
                Spacer()
                caps(c.title, size: 13, tracking: 2)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: -28) {
                    ForEach(c.bigParts, id: \.self) { part in
                        Text(part)
                            .font(.system(size: 132, weight: .black))
                            .tracking(-6)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                HStack(spacing: 16) {
                    Text("\(c.focus) FOCUS")
                    Text("\(c.pickups) PICKUPS")
                    Text(c.shortDate.uppercased())
                }
                .font(.system(size: 12, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 6)
            }
            .padding(24)
            .frame(width: CoverSize.width, height: CoverSize.height, alignment: .topLeading)
        }
    }
}

// MARK: - 18. Calendar

struct CalendarCover: View {
    let c: CoverContext
    private let ink = Color(white: 0.1)

    var body: some View {
        ZStack {
            CoverPhoto(image: c.blurred ?? c.photo)
            Color.black.opacity(0.35)
            VStack(spacing: 0) {
                ZStack {
                    Theme.accent
                    caps(Fmt.month.string(from: c.session.startDate), size: 16, tracking: 4)
                        .foregroundStyle(.white)
                }
                .frame(height: 58)
                VStack(spacing: 0) {
                    Text(Fmt.dayNumber.string(from: c.session.startDate))
                        .font(.system(size: 130, weight: .heavy))
                        .foregroundStyle(ink)
                    caps(Fmt.weekday.string(from: c.session.startDate), size: 13, tracking: 3)
                        .foregroundStyle(Color(white: 0.45))
                        .padding(.top, -12)
                    Rectangle()
                        .fill(Color(white: 0.88))
                        .frame(height: 1)
                        .padding(.vertical, 18)
                        .padding(.horizontal, 24)
                    Text("\(c.duration) in the tunnel")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(ink)
                    Text(c.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(white: 0.45))
                        .lineLimit(1)
                        .padding(.top, 4)
                    HStack(spacing: 26) {
                        mini("Focus", c.focus)
                        mini("Pickups", c.pickups)
                        mini("Streak", "\(c.streak)d")
                    }
                    .padding(.top, 16)
                }
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity)
                .background(Color.white)
            }
            .frame(width: 290)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .top) {
                HStack(spacing: 36) {
                    ForEach(0..<5, id: \.self) { _ in
                        Capsule().fill(Color(white: 0.8)).frame(width: 8, height: 26)
                    }
                }
                .offset(y: -12)
            }
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }

    private func mini(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            caps(label, size: 9).foregroundStyle(Color(white: 0.5))
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(ink)
        }
    }
}

// MARK: - 19. Sunset

struct SunsetCover: View {
    let c: CoverContext

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.08, blue: 0.35),
                    Color(red: 0.85, green: 0.25, blue: 0.35),
                    Color(red: 1.0, green: 0.6, blue: 0.25),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(Color(red: 1, green: 0.82, blue: 0.45).opacity(0.85))
                .frame(width: 220, height: 220)
                .offset(y: 170)
            VStack {
                BrandMark(size: 13, color: .white).padding(.top, 32)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(c.title)
                    .font(.system(size: 22, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(c.date)
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.75)
                    .padding(.top, 2)
                Text(c.clock)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .padding(.top, 14)
                HStack {
                    StatBlock(label: "Focus", value: c.focus, valueSize: 22)
                    Spacer()
                    StatBlock(label: "Pickups", value: c.pickups, valueSize: 22)
                    Spacer()
                    StatBlock(label: "Streak", value: "\(c.streak)d", valueSize: 22)
                }
                .padding(.top, 12)
                FocusProfileView(values: c.profile, color: .white, lineWidth: 1.5)
                    .frame(height: 44)
                    .padding(.top, 14)
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(width: 310)
            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.75))
        }
        .frame(width: CoverSize.width, height: CoverSize.height)
    }
}

// MARK: - 20. Tiles

struct TilesCover: View {
    let c: CoverContext

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverPhoto(image: c.blurred ?? c.photo)
            Color.black.opacity(0.45)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BrandMark(size: 13)
                    Spacer()
                    if c.streak > 0 { StreakPill(streak: c.streak) }
                }
                Text(c.title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 70)
                Text(c.date)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 10)
                HStack(spacing: 10) {
                    tile("Time", c.duration, icon: "clock.fill")
                    tile("Focus", c.focus, icon: "scope")
                }
                HStack(spacing: 10) {
                    tile("Pickups", c.pickups, icon: "hand.raised.fill")
                    tile("Focused", c.focused, icon: "checkmark.circle.fill")
                }
                VStack(alignment: .leading, spacing: 8) {
                    caps("Focus profile", size: 9)
                        .foregroundStyle(.white.opacity(0.6))
                    FocusProfileView(values: c.profile)
                        .frame(height: 56)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tileBackground)
            }
            .padding(20)
            .frame(width: CoverSize.width, height: CoverSize.height, alignment: .topLeading)
        }
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.75))
    }

    private func tile(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            StatBlock(label: label, value: value, valueSize: 24)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground)
    }
}
