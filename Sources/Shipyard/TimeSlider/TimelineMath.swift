import Foundation

// The arithmetic under `TimeSlider`, kept apart from the view so it can be tested (#3950).
//
// The day is 30 hours, NutriKit's model: a diary day's timeline runs from its local midnight for
// 120 quarter-hours, through 6 AM of the next calendar day, so a meal or a session at 00:45 on
// Nov 5 still belongs to (and sits on) Nov 4's evening. Minutes count from the day's local
// midnight in fixed 60 s steps, as NutriKit's always have.

/// The day's timeline: its quarter-hour slots and the minutes and dates they stand for.
enum TimelineSlots {
    /// 120 × 15 min = 30 hours: midnight to 6 AM the next day (FoodCore's `NumberOfTimeSlotsInADay`).
    static let count = 120
    static let minutesPerSlot = 15.0
    static let secondsPerSlot = minutesPerSlot * 60
    static let totalMinutes = Double(count) * minutesPerSlot
    /// Where a needle drag that zooms back out re-centres: the middle of the 30 hours.
    static let centreMinute = totalMinutes / 2

    static func minute(of date: Date, from dayStart: Date) -> Double {
        date.timeIntervalSince(dayStart) / 60
    }

    static func date(forMinute minute: Double, from dayStart: Date) -> Date {
        dayStart.addingTimeInterval(minute * 60)
    }

    /// The quarter-hour a minute falls in, clamped to the bar (#3948): a time past the 30 hours is
    /// on the last slot and one before midnight on the first.
    static func slot(forMinute minute: Double) -> Int {
        guard minute.isFinite else { return 0 }
        return min(max(Int((minute / minutesPerSlot).rounded(.down)), 0), count - 1)
    }

    /// The quarter-hour a date falls in on the day starting at `dayStart`, clamped to the bar.
    static func slot(of date: Date, from dayStart: Date) -> Int {
        slot(forMinute: minute(of: date, from: dayStart))
    }

    /// FoodCore's `Date.timeSlot(within:)`, as NutriKit's live timeline has always read the clock:
    /// a time at or before the day's midnight, or past its 30 hours, is slot 0. The live card
    /// leans on that 0 for a past or future day (its needle is drawn fresh at the finger, never
    /// slid in from where "now" would be), so it keeps the unclamped rule.
    static func liveSlot(of date: Date, from dayStart: Date) -> Int {
        guard date > dayStart else { return 0 }
        let slots = Int((date.timeIntervalSince1970 - dayStart.timeIntervalSince1970) / secondsPerSlot)
        guard slots < count else { return 0 }
        return slots
    }

    /// The start of a slot as a date (FoodCore's `Date.timeForTimeSlot(_:)`).
    static func date(forSlot slot: Int, from dayStart: Date) -> Date {
        Date(timeIntervalSince1970: dayStart.timeIntervalSince1970 + Double(slot) * secondsPerSlot)
    }

    /// A range of dates as the slots its ends fall in, unclamped (NutriKit's `asTimeSlots(for:)`).
    static func slotSpan(of range: ClosedRange<Date>, from dayStart: Date) -> ClosedRange<Int> {
        let lower = Int(range.lowerBound.timeIntervalSince(dayStart) / secondsPerSlot)
        let upper = Int(range.upperBound.timeIntervalSince(dayStart) / secondsPerSlot)
        return lower...max(upper, lower)
    }

    /// The end of the 30 hours as NutriKit's meals know it (FoodCore's `endOfPostMidnight`): 6 AM
    /// on the next calendar day, by the calendar, so a daylight-saving night is still "until 6 AM".
    static func endOfPostMidnight(for day: Date, calendar: Calendar = .current) -> Date {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(24 * 3600)
        return calendar.date(bySettingHour: 6, minute: 0, second: 0, of: nextDay)
            ?? calendar.startOfDay(for: nextDay).addingTimeInterval(6 * 3600)
    }

    /// The next calendar day's midnight: a time at or past it is "past midnight".
    static func nextMidnight(after dayStart: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)
    }

    /// A requested range held inside the 30 hours, in minutes, and never inverted (a "…now" range
    /// on a future day pins to its start).
    static func allowedMinutes(for requested: ClosedRange<Date>?, from dayStart: Date) -> ClosedRange<Double> {
        let requested = requested ?? dayStart...date(forMinute: totalMinutes, from: dayStart)
        let lower = min(max(minute(of: requested.lowerBound, from: dayStart), 0), totalMinutes)
        let upper = min(max(minute(of: requested.upperBound, from: dayStart), lower), totalMinutes)
        return lower...upper
    }

    /// The wheel picks a clock time, which before 6 AM could be either end of the 30-hour day: take
    /// whichever lies nearer the time being edited (so 11 PM rolled on to 1 AM is past midnight,
    /// and 2 AM rolled to 3 AM stays where it was), preferring one that's allowed, then held inside
    /// the allowed range (#3948).
    static func placeOnTimeline(
        _ picked: Date,
        near time: Date,
        dayStart: Date,
        nextMidnight: Date,
        allowed: ClosedRange<Date>,
        calendar: Calendar = .current
    ) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: picked)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        var candidates: [Date] = []
        if let sameDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart) {
            candidates.append(sameDay)
        }
        if hour < 6, let nextDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: nextMidnight) {
            candidates.append(nextDay)
        }
        let inRange = candidates.filter { allowed.contains($0) }
        let pool = inRange.isEmpty ? candidates : inRange
        let nearest = pool.min { abs($0.timeIntervalSince(time)) < abs($1.timeIntervalSince(time)) } ?? time
        return min(max(nearest, allowed.lowerBound), allowed.upperBound)
    }

    /// An axis label: "6a", "12p", "1:15a". The clock hour, so past 24h reads 12a, 1a… again,
    /// never 24, 25.
    static func axisLabel(forMinute minute: Int) -> String {
        let hour = (minute / 60) % 24
        let min = minute % 60
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "a" : "p"
        if min == 0 {
            return "\(h)\(ampm)"
        }
        return min < 10 ? "\(h):0\(min)\(ampm)" : "\(h):\(min)\(ampm)"
    }
}

/// An interval's two ends on the timeline, in minutes from the day's midnight (#3948).
///
/// The start carries the end with it at the length the interval had when the move began, so
/// picking a start keeps the length; the end alone changes the length. Both stay inside the
/// allowed range and the end at least `minimum` after the start; against the range's end the
/// start squeezes the interval, never below the minimum, and takes its length back when it
/// moves away again.
struct TimelineInterval: Equatable {
    enum Handle: Equatable { case start, end }

    var start: Double
    var end: Double

    var length: Double { max(end - start, 0) }

    /// The interval with its start moved to `minute`, the end carried `carried` minutes after it.
    func settingStart(
        _ minute: Double,
        carrying carried: Double,
        minimum: Double,
        allowed: ClosedRange<Double>
    ) -> TimelineInterval {
        let upper = allowed.upperBound
        let start = min(max(minute, allowed.lowerBound), max(upper - minimum, allowed.lowerBound))
        let end = min(max(start + carried, start + minimum), upper)
        return TimelineInterval(start: start, end: end)
    }

    /// The interval with its end alone moved to `minute`: at least `minimum` after the start, no
    /// further than the allowed range's end.
    func settingEnd(_ minute: Double, minimum: Double, allowed: ClosedRange<Double>) -> TimelineInterval {
        let lower = start + minimum
        let end = min(max(minute, lower), allowed.upperBound)
        return TimelineInterval(start: start, end: end)
    }

    /// The end nearer a minute. A tie (the finger between two needles a slot apart) goes to the
    /// end when right of the middle.
    func nearestHandle(toMinute minute: Double) -> Handle {
        abs(minute - end) < abs(minute - start) || minute > (start + end) / 2 ? .end : .start
    }
}

/// An interval's length: "45m", "1h", "1h 15m"; spoken in full words.
enum DurationText {
    static func short(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    static func spoken(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        let mins = m == 1 ? "1 minute" : "\(m) minutes"
        if h == 0 { return mins }
        return m == 0 ? hours : "\(hours) \(mins)"
    }
}
