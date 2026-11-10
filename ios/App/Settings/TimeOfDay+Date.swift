import DogMonitorCore
import Foundation

extension TimeOfDay {
    /// The hour and minute of `date` in `calendar`'s time zone.
    init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self = TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0) ?? QuietHours.suggested.start
    }

    /// Today at this time, for `DatePicker`.
    func date(calendar: Calendar = .current, on day: Date = .now) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

extension NotificationSettings {
    /// Quiet hours start as a `Date`, so a `DatePicker` can bind to it.
    var quietStartDate: Date {
        get { (quietHours?.start ?? QuietHours.suggested.start).date() }
        set {
            quietHours = QuietHours(
                start: TimeOfDay(date: newValue),
                end: quietHours?.end ?? QuietHours.suggested.end
            )
        }
    }

    var quietEndDate: Date {
        get { (quietHours?.end ?? QuietHours.suggested.end).date() }
        set {
            quietHours = QuietHours(
                start: quietHours?.start ?? QuietHours.suggested.start,
                end: TimeOfDay(date: newValue)
            )
        }
    }
}
