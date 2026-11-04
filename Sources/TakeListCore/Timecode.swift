import Foundation

/// How a timecode is written in a cell; new cells are written in the same style.
public enum TimecodeStyle: Equatable {
    /// HH:MM:SS:FF (separator before the frames may be `:`, `;`, `.` or `,`).
    case frames(separator: Character)
    /// HH:MM:SS.mmm
    case millis(separator: Character)
    /// HH:MM:SS
    case seconds
    /// Excel time value (fraction of a day).
    case excel
}

public struct Timecode {
    public let fps: Int
    public init(fps: Int) { self.fps = max(1, fps) }

    private static let regex = try! NSRegularExpression(pattern: #"^\s*(\d{1,2}):(\d{1,2}):(\d{1,2})(?:([:;.,])(\d{1,3}))?\s*$"#)
    private static let rangeRegex = try! NSRegularExpression(pattern: #"^\s*(\S+)\s*(?:-|–|—|/|bis|>)\s*(\S+)\s*$"#)

    /// Parses a timecode string. Returns frames and style, or nil.
    public func parse(_ string: String) -> (frames: Int, style: TimecodeStyle)? {
        let ns = string as NSString
        guard let m = Self.regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let h = Int(g(1)!), let mi = Int(g(2)!), let s = Int(g(3)!), mi < 60, s < 60 else { return nil }
        var frames = ((h * 60 + mi) * 60 + s) * fps
        guard let sep = g(4)?.first, let sub = g(5) else { return (frames, .seconds) }
        if (sep == "." || sep == ","), sub.count == 3 {
            frames += Int((Double(Int(sub)!) / 1000 * Double(fps)).rounded())
            return (frames, .millis(separator: sep))
        }
        guard let f = Int(sub), f < fps else { return nil }
        frames += f
        return (frames, .frames(separator: sep))
    }

    public func parse(_ cell: Cell) -> (frames: Int, style: TimecodeStyle)? {
        switch cell.value {
        case .number(let d) where d >= 0 && d < 10:
            return (Int((d * 86_400 * Double(fps)).rounded()), .excel)
        case .string(let s):
            return parse(s)
        default:
            return nil
        }
    }

    /// Parses a combined "IN - OUT" cell.
    public func parseRange(_ cell: Cell) -> (inF: Int, outF: Int, style: TimecodeStyle)? {
        let s = cell.text
        let ns = s as NSString
        guard let m = Self.rangeRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let a = parse(ns.substring(with: m.range(at: 1))),
              let b = parse(ns.substring(with: m.range(at: 2))) else { return nil }
        return (a.frames, b.frames, a.style)
    }

    public func string(_ frames: Int, style: TimecodeStyle) -> String {
        let f = max(0, frames)
        let totalSeconds = f / fps
        let h = totalSeconds / 3600, m = (totalSeconds / 60) % 60, s = totalSeconds % 60
        let base = String(format: "%02d:%02d:%02d", h, m, s)
        switch style {
        case .frames(let sep): return base + String(sep) + String(format: "%02d", f % fps)
        case .millis(let sep): return base + String(sep) + String(format: "%03d", Int(Double(f % fps) / Double(fps) * 1000))
        case .seconds: return base
        case .excel: return base + ":" + String(format: "%02d", f % fps)
        }
    }

    public func cellValue(_ frames: Int, style: TimecodeStyle) -> CellValue {
        if style == .excel { return .number(Double(frames) / Double(fps) / 86_400) }
        return .string(string(frames, style: style))
    }

    /// Smallest step a value of this style can express, in frames.
    public func quantum(for style: TimecodeStyle) -> Int {
        style == .seconds ? fps : 1
    }

    public func seconds(_ frames: Int) -> Double { Double(frames) / Double(fps) }
}
