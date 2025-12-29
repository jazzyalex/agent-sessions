import Foundation

enum AppDateFormatting {
    // MARK: - Session list / general UI

    static func dateTimeShort(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .shortened))
    }

    static func timeShort(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened))
    }

    static func dateTimeMedium(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .year()
                .month()
                .day()
                .hour(.defaultDigits(amPM: .abbreviated))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }

    // MARK: - Analytics labels

    static func weekdayAbbrev(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .weekday(.abbreviated)
        )
    }

    static func monthDayAbbrev(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
        )
    }

    static func hourLabel(_ date: Date) -> String {
        // Hour-only label that respects 12/24-hour settings.
        date.formatted(
            .dateTime
                .hour(.defaultDigits(amPM: .abbreviated))
        )
    }

    // MARK: - Transcript timestamps

    static let transcriptSeparator: String = " • "

    static func transcriptTimestamp(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .hour(.defaultDigits(amPM: .abbreviated))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }
}
