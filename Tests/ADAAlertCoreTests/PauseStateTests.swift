import Foundation
import Testing
@testable import ADAAlertCore

// Reading the pause file lib/ada-pause.sh writes, and the times the Pause menu
// offers. The shell side's rules (tested in test/ada-pause.bats) are the spec.
@Suite struct PauseStateTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String, in zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    @Test func zeroMeansUntilResumed() {
        #expect(PauseState.parse("0\n", now: now) == .paused(until: nil))
    }

    @Test func aFutureEpochIsPausedUntilThen() {
        #expect(PauseState.parse("1790003600\n", now: now) == .paused(until: Date(timeIntervalSince1970: 1_790_003_600)))
    }

    @Test func aPauseEndsAtItsEpochSecond() {
        #expect(PauseState.parse("1790000000", now: now) == .active)
        #expect(PauseState.parse("1789999999", now: now) == .active)
    }

    @Test func leadingZerosAreDecimal() {
        #expect(PauseState.parse("0001790003600", now: now) == .paused(until: Date(timeIntervalSince1970: 1_790_003_600)))
    }

    // Anything that isn't a pause file pauses nothing: the launcher fails open.
    @Test(arguments: ["", "\n", "soon", "-5", "12 34", "1.5", "1234567890123456", " 1790003600", "1790003600 "])
    func garbageIsNotAPause(_ text: String) {
        #expect(PauseState.parse(text, now: now) == .active)
    }

    @Test func onlyTheFirstLineCounts() {
        #expect(PauseState.parse("0\nignored\n", now: now) == .paused(until: nil))
        #expect(PauseState.parse("junk\n0\n", now: now) == .active)
    }

    @Test func readsARegularFileAndRefusesASymlinkOrDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("ada-paused")
        #expect(PauseState.read(fileAt: file, now: now) == .active)
        try "0\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(PauseState.read(fileAt: file, now: now) == .paused(until: nil))

        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(PauseState.read(fileAt: link, now: now) == .active)
        #expect(PauseState.read(fileAt: dir, now: now) == .active)
    }

    @Test func nextMorningIsTodayBeforeSevenAndTomorrowAfter() {
        let zone = "America/Los_Angeles"
        let cal = calendar(zone)
        #expect(PauseState.nextMorning(after: date("2026-09-24 02:00", in: zone), calendar: cal) == date("2026-09-24 08:00", in: zone))
        // Under an hour away: tomorrow instead, or the pause would barely last.
        #expect(PauseState.nextMorning(after: date("2026-09-24 07:30", in: zone), calendar: cal) == date("2026-09-25 08:00", in: zone))
        #expect(PauseState.nextMorning(after: date("2026-09-24 15:00", in: zone), calendar: cal) == date("2026-09-25 08:00", in: zone))
    }

    // 2026-03-08 springs forward in Los Angeles: a fixed 24h offset would land
    // on 09:00.
    @Test func nextMorningKeepsTheWallClockAcrossDST() {
        let zone = "America/Los_Angeles"
        #expect(PauseState.nextMorning(after: date("2026-03-07 20:00", in: zone), calendar: calendar(zone))
                == date("2026-03-08 08:00", in: zone))
    }

    @Test func titlesName_theEnd() {
        let zone = "UTC"
        let cal = calendar(zone)
        let noon = date("2026-09-24 12:00", in: zone)
        #expect(PauseState.active.title(now: noon, calendar: cal) == "Alerts On")
        #expect(PauseState.paused(until: nil).title(now: noon, calendar: cal) == "Paused Until Resumed")
        #expect(PauseState.paused(until: date("2026-09-24 15:30", in: zone)).title(now: noon, calendar: cal) == "Paused Until 15:30")
        #expect(PauseState.paused(until: date("2026-09-25 08:00", in: zone)).title(now: noon, calendar: cal) == "Paused Until Tomorrow 08:00")
        #expect(PauseState.describe(date("2026-09-27 09:15", in: zone), now: noon, calendar: cal) == "Sun 09:15")
        #expect(PauseState.describe(date("2026-10-20 09:15", in: zone), now: noon, calendar: cal) == "2026-10-20 09:15")
    }
}
