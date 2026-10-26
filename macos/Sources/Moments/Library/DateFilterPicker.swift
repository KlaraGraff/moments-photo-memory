import SwiftUI

/// How a date filter was picked. The filter itself is always a from/to pair
/// (either end may be open); the mode decides how clicks set it and how the
/// chip names it.
enum DateFilterMode: String, CaseIterable, Identifiable {
    /// Click a day for that day; click a second day for the days between.
    case days
    case after
    case before
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .days: return String(localized: "Days")
        case .after: return String(localized: "After")
        case .before: return String(localized: "Before")
        case .month: return String(localized: "Month")
        case .year: return String(localized: "Year")
        }
    }
}

/// The Date filter, picked like booking a hotel: one click is a day, a second
/// click makes it a stay. After, Before, Month and Year cover open-ended and
/// whole-period choices. Nothing is applied until a day, month or year is
/// clicked.
struct DateFilterPicker: View {
    @Binding var fromInterval: Double
    @Binding var toInterval: Double
    @Binding var modeRaw: String
    /// Start of every day that has photos; those days carry a dot.
    let photoDays: Set<Date>

    @State private var shownMonth: Date = .now
    @State private var shownYear: Int = Calendar.current.component(.year, from: .now)
    /// After the first click of a stay, the next click closes it.
    @State private var awaitingEnd = false

    private let calendar = Calendar.current

    private var mode: DateFilterMode {
        DateFilterMode(rawValue: modeRaw) ?? .days
    }

    private var from: Date? { fromInterval == 0 ? nil : Date(timeIntervalSince1970: fromInterval) }
    private var to: Date? { toInterval == 0 ? nil : Date(timeIntervalSince1970: toInterval) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(String(localized: "Pick by"), selection: Binding(
                get: { mode },
                set: { newMode in
                    modeRaw = newMode.rawValue
                    awaitingEnd = false
                    // After and Before are open on one side; drop the other
                    // end so what is highlighted is what is filtered.
                    if newMode == .after { toInterval = 0 }
                    if newMode == .before { fromInterval = 0 }
                }
            )) {
                ForEach(DateFilterMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("date-filter.mode")

            Group {
                switch mode {
                case .days, .after, .before:
                    monthCalendar
                case .month:
                    monthGrid
                case .year:
                    yearList
                }
            }
            .frame(height: 236, alignment: .top)

            HStack {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(String(localized: "Clear")) {
                    fromInterval = 0
                    toInterval = 0
                    awaitingEnd = false
                }
                .disabled(from == nil && to == nil)
                .accessibilityIdentifier("date-filter.clear")
            }
        }
        .padding(16)
        .frame(width: 320)
        .tint(Paper.accent)
        .onAppear {
            let anchor = from ?? to ?? photoDays.max() ?? .now
            shownMonth = startOfMonth(anchor)
            shownYear = calendar.component(.year, from: anchor)
        }
    }

    private var hint: String {
        switch mode {
        case .days:
            return awaitingEnd
                ? String(localized: "Click another day to pick the days in between.")
                : String(localized: "Click a day, or two days for the days in between.")
        case .after: return String(localized: "Photos from this day on.")
        case .before: return String(localized: "Photos up to and including this day.")
        case .month: return String(localized: "Photos from one month.")
        case .year: return String(localized: "Photos from one year.")
        }
    }

    // MARK: Days

    private var monthCalendar: some View {
        VStack(spacing: 8) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(String(localized: "Previous month"))
                Spacer()
                Text(shownMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                    .foregroundStyle(Paper.ink)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel(String(localized: "Next month"))
            }
            .buttonStyle(.borderless)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                let symbols = weekdaySymbols
                ForEach(0..<symbols.count, id: \.self) { index in
                    Text(symbols[index])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Paper.muted)
                        .frame(height: 18)
                }
                let cells = monthCells
                // Ids after the weekday row's, so the two never collide.
                ForEach(7..<(7 + cells.count), id: \.self) { index in
                    if let day = cells[index - 7] {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 30)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let selected = isEndpoint(day)
        let inRange = isInRange(day)
        let hasPhotos = photoDays.contains(day)
        return Button {
            pick(day)
        } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(selected ? Color.white : Paper.ink)
                Circle()
                    .fill(selected ? Color.white : Paper.accent)
                    .frame(width: 3.5, height: 3.5)
                    .opacity(hasPhotos ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
                if selected {
                    Circle().fill(Paper.accent).frame(width: 30, height: 30)
                } else if inRange {
                    Rectangle().fill(Paper.accent.opacity(0.14))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .long, time: .omitted))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("date-filter.day.\(calendar.component(.day, from: day))")
    }

    private func pick(_ day: Date) {
        switch mode {
        case .after:
            set(from: day, to: nil)
        case .before:
            set(from: nil, to: day)
        default:
            if awaitingEnd, let start = from {
                set(from: min(start, day), to: max(start, day))
                awaitingEnd = false
            } else {
                set(from: day, to: day)
                awaitingEnd = true
            }
        }
    }

    private func isEndpoint(_ day: Date) -> Bool {
        switch mode {
        case .after: return from == day
        case .before: return to == day
        default: return from == day || to == day
        }
    }

    private func isInRange(_ day: Date) -> Bool {
        switch mode {
        case .after: return from.map { day > $0 } ?? false
        case .before: return to.map { day < $0 } ?? false
        default:
            guard let from, let to else { return false }
            return day > from && day < to
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The shown month's days, padded with blanks to start on the right weekday.
    private var monthCells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: shownMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: shownMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: shownMonth) }
        return Array(repeating: nil, count: leading) + days
    }

    private func shiftMonth(_ delta: Int) {
        if let month = calendar.date(byAdding: .month, value: delta, to: shownMonth) {
            shownMonth = month
        }
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? calendar.startOfDay(for: date)
    }

    // MARK: Month and year

    private var monthGrid: some View {
        VStack(spacing: 10) {
            HStack {
                Button { shownYear -= 1 } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(String(localized: "Previous year"))
                Spacer()
                Text(String(shownYear))
                    .font(.headline)
                    .foregroundStyle(Paper.ink)
                Spacer()
                Button { shownYear += 1 } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel(String(localized: "Next year"))
            }
            .buttonStyle(.borderless)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(1...12, id: \.self) { month in
                    let start = calendar.date(from: DateComponents(year: shownYear, month: month, day: 1)) ?? .now
                    let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
                    let selected = from == start && to == end
                    let hasPhotos = photoDays.contains { $0 >= start && $0 <= end }
                    periodButton(
                        title: start.formatted(.dateTime.month(.abbreviated)),
                        selected: selected,
                        hasPhotos: hasPhotos
                    ) {
                        set(from: start, to: end)
                    }
                }
            }
        }
    }

    private var yearList: some View {
        let years = Set(photoDays.map { calendar.component(.year, from: $0) })
        let shown = years.isEmpty ? [calendar.component(.year, from: .now)] : years.sorted(by: >)
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(shown, id: \.self) { year in
                    let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .now
                    let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? start
                    periodButton(title: String(year), selected: from == start && to == end, hasPhotos: true) {
                        set(from: start, to: end)
                    }
                }
            }
        }
    }

    private func periodButton(title: String, selected: Bool, hasPhotos: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(selected ? Color.white : (hasPhotos ? Paper.ink : Paper.muted))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    selected ? Paper.accent : Paper.well.opacity(hasPhotos ? 0.9 : 0.4),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func set(from: Date?, to: Date?) {
        fromInterval = from.map { calendar.startOfDay(for: $0).timeIntervalSince1970 } ?? 0
        toInterval = to.map { calendar.startOfDay(for: $0).timeIntervalSince1970 } ?? 0
    }
}

extension DateFilterMode {
    /// The chip's words for a from/to pair picked in this mode.
    static func label(from: Date?, to: Date?, modeRaw: String) -> String? {
        // Named by the dates themselves, not the tab last looked at: a range
        // is called a month or a year only when it is exactly one.
        let calendar = Calendar.current
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted)
        switch (from, to) {
        case let (from?, to?) where from == to:
            return from.formatted(day)
        case let (from?, to?):
            let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: from)
            let yearEnd = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: from)
            if calendar.component(.day, from: from) == 1, to == monthEnd {
                return from.formatted(.dateTime.month(.wide).year())
            }
            if calendar.ordinality(of: .day, in: .year, for: from) == 1, to == yearEnd {
                return String(calendar.component(.year, from: from))
            }
            return DateIntervalFormatter.shortRange.string(from: from, to: to)
        case let (from?, nil):
            return String(format: String(localized: "From %@"), from.formatted(day))
        case let (nil, to?):
            return String(format: String(localized: "Until %@"), to.formatted(day))
        default:
            return nil
        }
    }
}

private extension DateIntervalFormatter {
    static let shortRange: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
