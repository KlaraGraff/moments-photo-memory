import SwiftData
import SwiftUI

/// Adjust Date and Time, for one photo (the viewer's date, the time under a
/// photo) or many (a selection in the Library). Like Photos: pick the time
/// of the earliest photo and every other photo moves by the same amount; a
/// new time zone keeps what the clock reads and applies to all of them.
struct PhotoDateEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SelectionModel.self) private var selection
    let items: [MediaItem]
    let dismiss: () -> Void

    @State private var draftDate = Date.now
    @State private var zone = TimeZone.autoupdatingCurrent
    @State private var originalZone = TimeZone.autoupdatingCurrent
    @State private var isReady = false

    private var reference: MediaItem? { DateTimeAdjustment.reference(in: items) }
    private var isBatch: Bool { items.count > 1 }
    private var zoneChanged: Bool { zone.identifier != originalZone.identifier }
    private var correctedCount: Int { items.filter { $0.userCorrectedCaptureDateUTC != nil }.count }

    /// How far every photo moves, e.g. "2 hours later".
    private var shiftDescription: String? {
        guard let current = reference?.effectiveCaptureDate else { return nil }
        let delta = draftDate.timeIntervalSince(current)
        guard abs(delta) >= 60 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.maximumUnitCount = 2
        guard let amount = formatter.string(from: abs(delta)) else { return nil }
        return delta > 0
            ? String(localized: "Every photo moves \(amount) later.")
            : String(localized: "Every photo moves \(amount) earlier.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isBatch
                 ? String(localized: "Adjust date and time of \(items.count) photos")
                 : String(localized: "Adjust date and time"))
                .font(.headline)
                .foregroundStyle(LibraryPalette.ink)
            if isBatch {
                Text(String(localized: "Set the time of the earliest photo; the others move by the same amount."))
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                DatePicker("", selection: $draftDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                DatePicker(String(localized: "Time"), selection: $draftDate, displayedComponents: [.hourAndMinute])
                    .datePickerStyle(.field)
                    .accessibilityIdentifier("date.editor.time")
            }
            // The pickers show the clock in the photo's time zone.
            .environment(\.timeZone, zone)
            .environment(\.calendar, calendar)
            HStack(spacing: 6) {
                Text(String(localized: "Time zone"))
                    .foregroundStyle(LibraryPalette.ink)
                TimeZoneMenu(zone: Binding(get: { zone }, set: changeZone))
            }
            VStack(alignment: .leading, spacing: 3) {
                if let original = reference?.captureDate,
                   reference?.userCorrectedCaptureDateUTC != nil || zoneChanged {
                    Text(String(localized: "Original: \(Self.fullText(original, in: originalZone))"))
                }
                if isBatch, let shiftDescription {
                    Text(shiftDescription)
                        .accessibilityIdentifier("date.editor.shift")
                }
            }
            .font(.caption)
            .foregroundStyle(LibraryPalette.muted)
            HStack {
                if correctedCount > 0, items.contains(where: { $0.captureDate != nil }) {
                    Button(isBatch ? String(localized: "Use original times") : String(localized: "Use original")) {
                        revert()
                    }
                }
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isBatch ? String(localized: "Adjust") : String(localized: "Done")) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("viewer.date.done")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear(perform: load)
    }

    private var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = zone
        return calendar
    }

    private func load() {
        guard !isReady else { return }
        isReady = true
        let photoZone = reference?.captureTimeZone ?? .autoupdatingCurrent
        zone = photoZone
        originalZone = photoZone
        draftDate = reference?.effectiveCaptureDate ?? .now
    }

    /// A new zone keeps the clock time the pickers show: 14:00 stays 14:00.
    private func changeZone(_ newZone: TimeZone) {
        draftDate = DateTimeAdjustment.keepingClockTime(draftDate, from: zone, to: newZone)
        zone = newZone
    }

    private func apply() {
        // Nothing changed: close without writing or offering an Undo.
        if !zoneChanged, let current = reference?.effectiveCaptureDate, abs(draftDate.timeIntervalSince(current)) < 1 {
            dismiss()
            return
        }
        let snapshot = DateTimeAdjustment.apply(to: items, referenceDate: draftDate, timeZone: zoneChanged ? zone : nil)
        finish(snapshot, message: isBatch
               ? String(localized: "Adjusted the date of \(items.count) photos")
               : String(localized: "Adjusted the date"))
    }

    private func revert() {
        let snapshot = DateTimeAdjustment.revert(items)
        finish(snapshot, message: String(localized: "Back to the original time"))
    }

    private func finish(_ snapshot: DateTimeAdjustment.Snapshot, message: String) {
        try? modelContext.save()
        if !snapshot.items.isEmpty {
            selection.recordCorrection(CorrectionUndo(
                message: message,
                actionName: String(localized: "Adjust Date and Time"),
                restore: { context in DateTimeAdjustment.restore(snapshot, context: context) }
            ), context: modelContext)
        }
        dismiss()
    }

    static func dayText(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = zone
        return date.formatted(style)
    }

    static func timeText(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return date.formatted(style)
    }

    static func fullText(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = zone
        return date.formatted(style)
    }
}

/// The sheet the window opens for Adjust Date and Time on several photos.
struct DateAdjustmentSheet: View {
    @Environment(SelectionModel.self) private var selection
    @Query private var items: [MediaItem]

    init(itemIDs: [String]) {
        _items = Query(filter: #Predicate<MediaItem> { itemIDs.contains($0.id) })
    }

    var body: some View {
        PhotoDateEditor(items: items) { selection.dateAdjustmentItemIDs = nil }
            .background(Paper.raised)
    }
}

/// A time zone picker: the photo's zone and this Mac's first, then every
/// zone by region, each named by its city and offset.
struct TimeZoneMenu: View {
    @Binding var zone: TimeZone

    private struct Region: Identifiable {
        let id: String
        let zones: [String]
    }

    private static let regions: [Region] = {
        let grouped = Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }) {
            String($0.split(separator: "/").first ?? "")
        }
        return grouped.keys.sorted().map { Region(id: $0, zones: grouped[$0, default: []].sorted()) }
    }()

    var body: some View {
        Menu {
            Section {
                zoneButton(zone)
                if TimeZone.autoupdatingCurrent.identifier != zone.identifier {
                    zoneButton(.autoupdatingCurrent)
                }
            }
            ForEach(Self.regions) { region in
                Menu(Self.regionName(region.id)) {
                    ForEach(region.zones, id: \.self) { identifier in
                        if let candidate = TimeZone(identifier: identifier) { zoneButton(candidate) }
                    }
                }
            }
        } label: {
            Text(Self.label(for: zone))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("date.editor.zone")
    }

    private func zoneButton(_ candidate: TimeZone) -> some View {
        Button(Self.label(for: candidate)) { zone = candidate }
    }

    /// "Tokyo (GMT+9)".
    static func label(for zone: TimeZone) -> String {
        let city = zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
        return "\(city) (\(offsetText(for: zone)))"
    }

    static func offsetText(for zone: TimeZone, at date: Date = .now) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        let sign = seconds < 0 ? "-" : "+"
        if seconds == 0 { return "GMT" }
        return minutes == 0 ? "GMT\(sign)\(hours)" : String(format: "GMT\(sign)%d:%02d", hours, minutes)
    }

    private static func regionName(_ id: String) -> String {
        switch id {
        case "Africa": return String(localized: "Africa")
        case "America": return String(localized: "Americas")
        case "Antarctica": return String(localized: "Antarctica")
        case "Arctic": return String(localized: "Arctic")
        case "Asia": return String(localized: "Asia")
        case "Atlantic": return String(localized: "Atlantic")
        case "Australia": return String(localized: "Australia")
        case "Europe": return String(localized: "Europe")
        case "Indian": return String(localized: "Indian Ocean")
        case "Pacific": return String(localized: "Pacific")
        default: return id
        }
    }
}
