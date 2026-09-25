import Foundation

/// Whether alerts are paused, read from the file `lib/ada-pause.sh` writes: one
/// decimal integer, the epoch second the pause ends, or `0` for until resumed.
/// The shell side owns every write; this only reads, with the same rules the
/// launcher applies (a symlink, a directory or anything that isn't a number
/// pauses nothing, and a pause whose end has passed is over).
public enum PauseState: Equatable {
    case active
    /// `until` is nil for a pause that lasts until resumed.
    case paused(until: Date?)

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    public static func read(fileAt url: URL, now: Date, fileManager: FileManager = .default) -> PauseState {
        guard isRegularFile(url, fileManager: fileManager),
              let data = fileManager.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)
        else {
            return .active
        }
        return parse(text, now: now)
    }

    public static func parse(_ text: String, now: Date) -> PauseState {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard (1...15).contains(line.count), line.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int64(line)
        else {
            return .active
        }
        if value == 0 { return .paused(until: nil) }
        let end = Date(timeIntervalSince1970: TimeInterval(value))
        return now < end ? .paused(until: end) : .active
    }

    /// The next 08:00 local time, pushed a day when that is less than an hour
    /// away, so "until tomorrow" at 07:30 does not end half an hour later.
    /// `Calendar.nextDate` keeps it right across a DST change.
    public static func nextMorning(after now: Date, calendar: Calendar, hour: Int = 8) -> Date {
        let components = DateComponents(hour: hour, minute: 0, second: 0)
        guard var morning = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) else {
            return now.addingTimeInterval(24 * 3600)
        }
        if morning.timeIntervalSince(now) < 3600,
           let later = calendar.nextDate(after: morning, matching: components, matchingPolicy: .nextTime) {
            morning = later
        }
        return morning
    }

    /// The first line of the menu.
    public func title(now: Date, calendar: Calendar) -> String {
        switch self {
        case .active:
            return "Alerts On"
        case .paused(until: nil):
            return "Paused Until Resumed"
        case .paused(until: let end?):
            return "Paused Until \(Self.describe(end, now: now, calendar: calendar))"
        }
    }

    /// "15:30" today, "Tomorrow 08:00", "Fri 15:30" within a week, else a date.
    public static func describe(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = Self.format("HH:mm", date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        if date.timeIntervalSince(now) < 6 * 24 * 3600 {
            return Self.format("EEE HH:mm", date, calendar: calendar)
        }
        return Self.format("yyyy-MM-dd HH:mm", date, calendar: calendar)
    }

    static func format(_ pattern: String, _ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
