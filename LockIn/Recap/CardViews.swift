import SwiftUI

/// Where the ticking clock and progress bar sit in the shared video, as fractions of the frame
/// (measured from the top). The overlay image leaves these spots empty.
enum OverlayLayout {
    static let sideInset: CGFloat = 0.07
    static let timerTop: CGFloat = 0.665
    static let timerHeight: CGFloat = 0.085
    static let barTop: CGFloat = 0.768
    static let barHeight: CGFloat = 0.006
}

struct BrandMark: View {
    var size: CGFloat = 13
    var color: Color = Theme.accent

    var body: some View {
        HStack(spacing: size * 0.35) {
            Image(systemName: "circle.circle.fill")
                .font(.system(size: size * 0.9, weight: .black))
            Text("TUNNEL")
                .font(.system(size: size, weight: .black))
                .italic()
                .tracking(size * 0.12)
        }
        .foregroundStyle(color)
    }
}

struct StatBlock: View {
    let label: String
    let value: String
    var valueSize: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: valueSize * 0.08) {
            Text(label.uppercased())
                .font(.system(size: max(9, valueSize * 0.38), weight: .semibold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.65))
            Text(value)
                .font(.system(size: valueSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

/// The "elevation profile" of a session: high = focused, dips = phone pickups.
struct FocusProfileView: View {
    let values: [Double]
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            ProfileShape(values: values, closed: true)
                .fill(LinearGradient(colors: [color.opacity(0.55), color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
            ProfileShape(values: values, closed: false)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

struct ProfileShape: Shape {
    let values: [Double]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let data = values.count > 1 ? values : [1, 1]
        let points = data.enumerated().map { index, value in
            CGPoint(
                x: rect.minX + rect.width * CGFloat(index) / CGFloat(data.count - 1),
                y: rect.maxY - rect.height * CGFloat(0.1 + 0.85 * value)
            )
        }
        path.move(to: points[0])
        for i in 1..<points.count {
            let previous = points[i - 1]
            let current = points[i]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: points[points.count - 1])
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Sticker (transparent PNG to drop on your own photo)

struct StickerView: View {
    let session: FocusSession
    let streak: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BrandMark(size: 14, color: .white)
            Text(session.title)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 12) {
                StatBlock(label: "Time", value: Fmt.duration(session.duration), valueSize: 34)
                HStack(spacing: 28) {
                    StatBlock(label: "Focus", value: "\(session.focusScore)%", valueSize: 26)
                    StatBlock(label: "Pickups", value: "\(session.pickups)", valueSize: 26)
                }
            }
            FocusProfileView(values: session.focusProfile(buckets: 30), color: .white, lineWidth: 2.5)
                .frame(height: 50)
            if streak > 1 {
                Label("\(streak) day streak", systemImage: "flame.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(20)
        .frame(width: 300, alignment: .leading)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}

// MARK: - Video overlay (static parts; the clock and progress bar are animated separately)

struct VideoOverlayView: View {
    let session: FocusSession
    /// Size in points; rendered at 3× to match the video's pixel size.
    let size: CGSize
    let streak: Int

    var body: some View {
        let w = size.width
        let h = size.height
        let inner = w * (1 - OverlayLayout.sideInset * 2)

        ZStack(alignment: .topLeading) {
            Color.clear
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: w, height: h * 0.16)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.7), location: 0.35),
                    .init(color: .black.opacity(0.9), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: w, height: h * 0.5)
            .offset(y: h * 0.5)

            HStack(alignment: .firstTextBaseline) {
                BrandMark(size: w * 0.042)
                Spacer()
                Text(Fmt.dateTime.string(from: session.startDate))
                    .font(.system(size: w * 0.032, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: inner)
            .position(x: w / 2, y: h * 0.05)

            Text(session.title)
                .font(.system(size: w * 0.06, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: inner, alignment: .leading)
                .position(x: w / 2, y: h * (OverlayLayout.timerTop - 0.022))

            HStack(alignment: .top, spacing: w * 0.09) {
                StatBlock(label: "Focus", value: "\(session.focusScore)%", valueSize: w * 0.065)
                StatBlock(label: "Pickups", value: "\(session.pickups)", valueSize: w * 0.065)
                if streak > 0 {
                    StatBlock(label: "Streak", value: "\(streak)d", valueSize: w * 0.065)
                }
            }
            .frame(width: inner, alignment: .leading)
            .position(x: w / 2, y: h * 0.835)

            FocusProfileView(values: session.focusProfile(buckets: 40), lineWidth: max(1.5, w * 0.006))
                .frame(width: inner, height: h * 0.055)
                .position(x: w / 2, y: h * 0.925)
        }
        .frame(width: w, height: h)
    }
}
