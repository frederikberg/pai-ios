import PAIKit
import SwiftUI

/// A day: the quick choices, then any day of a month.
struct TodoDayPickerScreen: View {
    let title: String
    let today: String
    var maxDate: String?
    /// Nil means "none".
    var clearLabel: String?
    let onPick: (String?) -> Void

    @State private var picked = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TodoWords.quickDays(today).filter { maxDate == nil || $0.date <= maxDate! }, id: \.date) {
                        quick in
                        Button {
                            onPick(quick.date)
                        } label: {
                            HStack {
                                Text(quick.label)
                                Spacer()
                                Text(TodoWords.dayHeading(quick.date, today: today).label)
                                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                            }
                        }
                    }
                    if let clearLabel {
                        Button(clearLabel, role: .destructive) { onPick(nil) }
                    }
                }
                Section {
                    DatePicker("Day", selection: $picked, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                    Button("Choose this day") { onPick(Self.iso(picked)) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    static func iso(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// A time of day as a date a wheel can show and back, read on a fixed clock so the phone's own
/// zone never moves it.
enum TodoClock {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ text: String) -> Date {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return Date() }
        return calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: parts[0], minute: parts[1]))
            ?? Date()
    }

    static func hhmm(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
