import Foundation
import Testing
@testable import Shipyard

// The TimeSlider's arithmetic (#3950): the 30-hour day's slots, the clamp at its ends, the wheel's
// placement of a clock time before 6 AM, and the interval's invariants.

/// A fixed calendar, so the tests don't depend on the Mac's zone (a daylight-saving night would
/// otherwise move "6 AM tomorrow" by an hour).
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Indian/Maldives")!
    return calendar
}()

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private let dayStart = at(4, 0)
private let nextMidnight = at(5, 0)
private let wholeDay = dayStart...at(5, 6)

@Suite("Timeline slots")
struct TimelineSlotTests {
    @Test func theDayIsThirtyHoursOfQuarterHours() {
        #expect(TimelineSlots.count == 120)
        #expect(TimelineSlots.totalMinutes == 1800)
        #expect(TimelineSlots.centreMinute == 900)
    }

    @Test func minutesAndDatesRoundTrip() {
        let lunch = at(4, 12, 40)
        let minute = TimelineSlots.minute(of: lunch, from: dayStart)
        #expect(minute == 760)
        #expect(TimelineSlots.date(forMinute: minute, from: dayStart) == lunch)
    }

    @Test func aMinuteFallsInItsQuarterHour() {
        #expect(TimelineSlots.slot(forMinute: 0) == 0)
        #expect(TimelineSlots.slot(forMinute: 14.9) == 0)
        #expect(TimelineSlots.slot(forMinute: 15) == 1)
        #expect(TimelineSlots.slot(forMinute: 760) == 50)
        #expect(TimelineSlots.slot(forMinute: 1799) == 119)
    }

    @Test func theSlotLookupClampsToTheBar() {
        // Past the 30 hours: the last slot, never 0 (which put a late time on midnight).
        #expect(TimelineSlots.slot(forMinute: 1800) == 119)
        #expect(TimelineSlots.slot(forMinute: 5000) == 119)
        #expect(TimelineSlots.slot(of: at(5, 9), from: dayStart) == 119)
        // Before midnight: the first.
        #expect(TimelineSlots.slot(forMinute: -30) == 0)
        #expect(TimelineSlots.slot(of: at(3, 23), from: dayStart) == 0)
        #expect(TimelineSlots.slot(forMinute: .nan) == 0)
    }

    @Test func theLiveClockKeepsFoodCoresRule() {
        // NutriKit's live card reads a time outside the 30 hours as slot 0 (FoodCore's
        // `timeSlot(within:)`), and leans on it for a past or future day.
        #expect(TimelineSlots.liveSlot(of: at(4, 12, 40), from: dayStart) == 50)
        #expect(TimelineSlots.liveSlot(of: dayStart, from: dayStart) == 0)
        #expect(TimelineSlots.liveSlot(of: at(5, 5, 59), from: dayStart) == 119)
        #expect(TimelineSlots.liveSlot(of: at(5, 6), from: dayStart) == 0)
        #expect(TimelineSlots.liveSlot(of: at(3, 20), from: dayStart) == 0)
    }

    @Test func aSlotStartsOnItsQuarterHour() {
        #expect(TimelineSlots.date(forSlot: 0, from: dayStart) == dayStart)
        #expect(TimelineSlots.date(forSlot: 50, from: dayStart) == at(4, 12, 30))
        #expect(TimelineSlots.date(forSlot: 100, from: dayStart) == at(5, 1))
    }

    @Test func aRangeBecomesTheSlotsItsEndsFallIn() {
        #expect(TimelineSlots.slotSpan(of: at(4, 6)...at(4, 12, 40), from: dayStart) == 24...50)
        // NutriKit's meals run to 5 minutes before 6 AM: the last slot, 119.
        #expect(TimelineSlots.slotSpan(of: dayStart...at(5, 5, 55), from: dayStart) == 0...119)
    }

    @Test func theDayEndsAtSixTheNextMorning() {
        #expect(TimelineSlots.endOfPostMidnight(for: at(4, 15), calendar: calendar) == at(5, 6))
        #expect(TimelineSlots.nextMidnight(after: dayStart, calendar: calendar) == nextMidnight)
    }

    @Test func anAllowedRangeIsHeldInsideTheThirtyHours() {
        #expect(TimelineSlots.allowedMinutes(for: nil, from: dayStart) == 0...1800)
        #expect(TimelineSlots.allowedMinutes(for: at(3, 20)...at(5, 9), from: dayStart) == 0...1800)
        #expect(TimelineSlots.allowedMinutes(for: at(4, 8)...at(4, 20), from: dayStart) == 480...1200)
        // An empty range, or one wholly before the day, pins to its start.
        #expect(TimelineSlots.allowedMinutes(for: at(4, 9)...at(4, 9), from: dayStart) == 540...540)
        #expect(TimelineSlots.allowedMinutes(for: at(2, 9)...at(3, 9), from: dayStart) == 0...0)
    }

    @Test func axisLabelsReadTheClockPastMidnight() {
        #expect(TimelineSlots.axisLabel(forMinute: 0) == "12a")
        #expect(TimelineSlots.axisLabel(forMinute: 360) == "6a")
        #expect(TimelineSlots.axisLabel(forMinute: 720) == "12p")
        #expect(TimelineSlots.axisLabel(forMinute: 795) == "1:15p")
        #expect(TimelineSlots.axisLabel(forMinute: 1445) == "12:05a")
        #expect(TimelineSlots.axisLabel(forMinute: 1500) == "1a")
        #expect(TimelineSlots.axisLabel(forMinute: 1800) == "6a")
    }
}

@Suite("The wheel past midnight")
struct WheelPlacementTests {
    private func place(_ picked: Date, near time: Date, allowed: ClosedRange<Date> = wholeDay) -> Date {
        TimelineSlots.placeOnTimeline(picked, near: time, dayStart: dayStart, nextMidnight: nextMidnight,
                                      allowed: allowed, calendar: calendar)
    }

    @Test func elevenRolledOnToOneIsPastMidnight() {
        // The wheel hands back 1 AM on whatever day the bound date had: either end could be meant.
        #expect(place(at(4, 1), near: at(4, 23)) == at(5, 1))
        #expect(place(at(5, 1), near: at(4, 23)) == at(5, 1))
    }

    @Test func twoRolledToThreeStaysWhereItWas() {
        #expect(place(at(5, 3), near: at(5, 2)) == at(5, 3))
        #expect(place(at(4, 3), near: at(4, 2)) == at(4, 3))
    }

    @Test func eightRolledToFiveStaysOnTheDay() {
        #expect(place(at(4, 5), near: at(4, 8)) == at(4, 5))
    }

    @Test func aTimeFromSixOnIsOnlyEverTheDaysOwn() {
        #expect(place(at(5, 7), near: at(5, 1)) == at(4, 7))
        #expect(place(at(4, 23, 30), near: at(5, 0, 30)) == at(4, 23, 30))
    }

    @Test func anAllowedEndIsPreferred() {
        // Only the evening is allowed: 1 AM can only be tomorrow's, even near a morning time.
        let evening = at(4, 18)...at(5, 6)
        #expect(place(at(4, 1), near: at(4, 19)) == at(5, 1))
        #expect(place(at(4, 1), near: at(4, 2)) == at(4, 1))
        #expect(place(at(4, 1), near: at(4, 2), allowed: evening) == at(5, 1))
    }

    @Test func aPickOutsideTheRangeIsHeldInsideIt() {
        // Today, until now (2 PM): 4 PM can't be had, so the wheel lands on now.
        let untilNow = dayStart...at(4, 14)
        #expect(place(at(4, 16), near: at(4, 12), allowed: untilNow) == at(4, 14))
    }
}

@Suite("Interval invariants")
struct IntervalTests {
    private let allowed: ClosedRange<Double> = 0...1800
    private let minimum = 5.0

    /// End ≥ start + minimum, both inside the range.
    private func holds(_ interval: TimelineInterval, in range: ClosedRange<Double>) -> Bool {
        interval.end >= interval.start + minimum - 1e-9
            && range.contains(interval.start) && range.contains(interval.end)
    }

    @Test func theStartCarriesTheEndAtItsLength() {
        let workout = TimelineInterval(start: 600, end: 660)
        let moved = workout.settingStart(720, carrying: workout.length, minimum: minimum, allowed: allowed)
        #expect(moved == TimelineInterval(start: 720, end: 780))
        #expect(holds(moved, in: allowed))
    }

    @Test func theEndAloneChangesTheLength() {
        let workout = TimelineInterval(start: 600, end: 660)
        #expect(workout.settingEnd(705, minimum: minimum, allowed: allowed) == TimelineInterval(start: 600, end: 705))
    }

    @Test func theEndStaysTheMinimumAfterTheStart() {
        let workout = TimelineInterval(start: 600, end: 660)
        let squeezed = workout.settingEnd(550, minimum: minimum, allowed: allowed)
        #expect(squeezed.end == 605)
        #expect(holds(squeezed, in: allowed))
    }

    @Test func theStartSqueezesAgainstTheUpperBoundAndTakesItsLengthBack() {
        let workout = TimelineInterval(start: 1600, end: 1690)
        // Pushed against 1800 the interval squeezes, never below the minimum…
        let pushed = workout.settingStart(1780, carrying: 90, minimum: minimum, allowed: allowed)
        #expect(pushed == TimelineInterval(start: 1780, end: 1800))
        #expect(holds(pushed, in: allowed))
        let pinned = workout.settingStart(1900, carrying: 90, minimum: minimum, allowed: allowed)
        #expect(pinned == TimelineInterval(start: 1795, end: 1800))
        #expect(holds(pinned, in: allowed))
        // …and the carried length comes back as the start moves away again.
        let back = pinned.settingStart(1600, carrying: 90, minimum: minimum, allowed: allowed)
        #expect(back == TimelineInterval(start: 1600, end: 1690))
    }

    @Test func bothEndsStayInsideARange() {
        let range: ClosedRange<Double> = 480...1200
        let workout = TimelineInterval(start: 600, end: 660)
        let early = workout.settingStart(100, carrying: 60, minimum: minimum, allowed: range)
        #expect(early == TimelineInterval(start: 480, end: 540))
        let late = workout.settingEnd(1500, minimum: minimum, allowed: range)
        #expect(late.end == 1200)
        for start in stride(from: 300.0, through: 1400, by: 37) {
            for carried in [0.0, 3, 45, 300, 900] {
                let next = workout.settingStart(start, carrying: carried, minimum: minimum, allowed: range)
                #expect(holds(next, in: range), "start \(start), carried \(carried)")
                for end in stride(from: 300.0, through: 1400, by: 53) {
                    #expect(holds(next.settingEnd(end, minimum: minimum, allowed: range), in: range))
                }
            }
        }
    }

    @Test func aRangeShorterThanTheMinimumStillHoldsTheStartInside() {
        let tight: ClosedRange<Double> = 600...602
        let next = TimelineInterval(start: 600, end: 660).settingStart(601, carrying: 60, minimum: minimum, allowed: tight)
        #expect(next.start == 600)
        #expect(next.end == 602)
    }

    @Test func aDragTakesTheNearerEnd() {
        let workout = TimelineInterval(start: 600, end: 660)
        #expect(workout.nearestHandle(toMinute: 590) == .start)
        #expect(workout.nearestHandle(toMinute: 620) == .start)
        #expect(workout.nearestHandle(toMinute: 640) == .end)
        #expect(workout.nearestHandle(toMinute: 700) == .end)
        // A tie between needles a slot apart goes to the end right of the middle.
        let close = TimelineInterval(start: 600, end: 615)
        #expect(close.nearestHandle(toMinute: 608) == .end)
        #expect(close.nearestHandle(toMinute: 607.5) == .start)
    }

    @Test func lengthsReadShortAndSpoken() {
        #expect(DurationText.short(minutes: 45) == "45m")
        #expect(DurationText.short(minutes: 60) == "1h")
        #expect(DurationText.short(minutes: 75) == "1h 15m")
        #expect(DurationText.spoken(minutes: 61) == "1 hour 1 minute")
        #expect(DurationText.spoken(minutes: 120) == "2 hours")
    }
}

@Suite("Interval pills")
struct IntervalPillsLayoutTests {
    @Test func pillsSitOverTheirNeedlesWhenThereIsRoom() {
        let xs = IntervalPillsLayout.centres(startX: 60, endX: 300, widths: (60, 40, 60), gap: 8, edgePadding: 8, width: 360)
        #expect(xs.start == 60)
        #expect(xs.chip == 180)
        #expect(xs.end == 300)
    }

    @Test func closeNeedlesPushThePillsApartWithoutOverlap() {
        let xs = IntervalPillsLayout.centres(startX: 170, endX: 190, widths: (60, 40, 60), gap: 8, edgePadding: 8, width: 360)
        #expect(xs.chip - 20 - (xs.start + 30) >= 8 - 1e-9)
        #expect(xs.end - 30 - (xs.chip + 20) >= 8 - 1e-9)
        #expect(xs.chip == 180)
    }

    @Test func thePillsAreHeldClearOfBothEdges() {
        let left = IntervalPillsLayout.centres(startX: 0, endX: 10, widths: (60, 40, 60), gap: 8, edgePadding: 8, width: 360)
        #expect(left.start - 30 >= 8)
        let right = IntervalPillsLayout.centres(startX: 350, endX: 360, widths: (60, 40, 60), gap: 8, edgePadding: 8, width: 360)
        #expect(right.end + 30 <= 352)
        #expect(right.chip + 20 + 8 <= right.end - 30 + 1e-9)
    }
}
