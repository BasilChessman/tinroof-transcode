import Foundation

public enum Timecode {
    /// Formats seconds as `H:MM:SS.ff` where ff is hundredths.
    public static func format(_ seconds: Double, showHours: Bool = true) -> String {
        guard seconds.isFinite else { return "--:--:--" }
        let negative = seconds < 0
        let total = (abs(seconds) * 100).rounded()
        let hundredths = Int(total.truncatingRemainder(dividingBy: 100))
        let whole = Int(total / 100)
        let h = whole / 3600, m = (whole / 60) % 60, s = whole % 60
        let body = showHours || h > 0
            ? String(format: "%d:%02d:%02d.%02d", h, m, s, hundredths)
            : String(format: "%02d:%02d.%02d", m, s, hundredths)
        return negative ? "-" + body : body
    }

    /// Formats seconds for ffmpeg arguments (`seconds.micro`).
    public static func ffmpeg(_ seconds: Double) -> String {
        String(format: "%.6f", max(0, seconds))
    }

    /// Parses `H:MM:SS.ff`, `MM:SS`, `SS.sss`, or colon-less digit runs such as `10203` (1:02:03).
    public static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count <= 3 else { return nil }
            var value = 0.0
            for p in parts {
                guard let v = Double(p.isEmpty ? "0" : p), v >= 0 else { return nil }
                value = value * 60 + v
            }
            return value
        }
        // Colon-less digit runs are read as HHMMSS from the right, with an optional fraction.
        let pieces = t.split(separator: ".", maxSplits: 1).map(String.init)
        let digits = pieces[0]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return Double(t) }
        let fraction = pieces.count > 1 ? (Double("0." + pieces[1]) ?? 0) : 0
        if digits.count <= 2 { return Double(digits)! + fraction }
        let padded = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
        let chars = Array(padded)
        let hours = Double(String(chars[0..<(chars.count - 4)]))!
        let minutes = Double(String(chars[(chars.count - 4)..<(chars.count - 2)]))!
        let secs = Double(String(chars[(chars.count - 2)...]))!
        return hours * 3600 + minutes * 60 + secs + fraction
    }

    /// Parses the Go-to-Time syntax: `T` (go), `T-` (set In), `-T` (set Out), `A-B` (selection).
    public enum GoToRequest: Equatable {
        case time(Double)
        case setIn(Double)
        case setOut(Double)
        case selection(Double, Double)
    }

    public static func parseGoTo(_ text: String) -> GoToRequest? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let dash = t.firstIndex(of: "-") {
            let left = String(t[..<dash]), right = String(t[t.index(after: dash)...])
            switch (parse(left), parse(right)) {
            case let (a?, b?): return .selection(min(a, b), max(a, b))
            case let (a?, nil) where right.trimmingCharacters(in: .whitespaces).isEmpty: return .setIn(a)
            case let (nil, b?) where left.trimmingCharacters(in: .whitespaces).isEmpty: return .setOut(b)
            default: return nil
            }
        }
        return parse(t).map(GoToRequest.time)
    }
}
