import SwiftUI
import UIKit

enum Theme {
    static let accentUIColor = UIColor(red: 1.0, green: 0.36, blue: 0.10, alpha: 1)
    static let accent = Color(uiColor: accentUIColor)
    static let card = Color(white: 0.10)
}

enum Fmt {
    /// "1h 42m", "12m 5s", "40s"
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// "1:42:05" or "42:05"
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// ["2H", "14M"] or ["14M", "5S"], for big stacked type.
    static func bigParts(_ t: TimeInterval) -> [String] {
        let s = max(0, Int(t.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? ["\(h)H", "\(m)M"] : ["\(m)M", "\(sec)S"]
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static let dateTime = formatter("EEE MMM d jmm")
    static let weekdayLetter = formatter("EEEEE")
    static let weekday = formatter("EEEE")
    static let shortDate = formatter("MMM d")
    static let month = formatter("MMMM")
    static let dayNumber = formatter("d")
    static let timeOnly = formatter("jmm")
}
