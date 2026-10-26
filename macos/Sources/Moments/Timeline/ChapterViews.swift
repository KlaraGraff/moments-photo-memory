import SwiftUI
import SwiftData

/// The kinds above the chapter cards: All, then each kind that has
/// chapters. Icons and names when there is room, icons alone when not.
struct ChapterFilterBar: View {
    let types: [ChapterType]
    @Binding var filterRaw: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips(showsLabels: true)
            chips(showsLabels: false)
        }
    }

    private func chips(showsLabels: Bool) -> some View {
        HStack(spacing: 6) {
            chip(raw: "", label: String(localized: "All"), symbol: "square.stack", showsLabel: true)
            ForEach(types) { type in
                chip(raw: type.raw, label: type.filterLabel, symbol: type.defaultSymbol, showsLabel: showsLabels)
            }
        }
        .fixedSize()
    }

    private func chip(raw: String, label: String, symbol: String, showsLabel: Bool) -> some View {
        let isOn = filterRaw == raw
        return Button {
            filterRaw = raw
        } label: {
            Group {
                if showsLabel {
                    Label(label, systemImage: symbol)
                } else {
                    Image(systemName: symbol)
                }
            }
            .font(.callout)
            .foregroundStyle(isOn ? Paper.raised : Paper.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(isOn ? Paper.accent : Paper.well, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("chapters.filter.\(raw.isEmpty ? "all" : raw)")
    }
}

/// A celebration's side of its card: the day, large, and how long ago it was.
struct ChapterAnniversary: View {
    let date: Date
    @Environment(\.locale) private var locale

    private var yearsAgo: Int {
        Calendar.current.dateComponents([.year], from: date, to: .now).year ?? 0
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(date, format: .dateTime.day().locale(locale))
                .font(.system(size: 44, weight: .medium, design: .serif))
                .foregroundStyle(Paper.ink)
            Text(date, format: .dateTime.month(.wide).year().locale(locale))
                .font(.footnote)
                .foregroundStyle(Paper.muted)
            Text(yearsAgo > 0 ? String(localized: "\(yearsAgo) years ago") : String(localized: "This year"))
                .font(.caption.weight(.medium))
                .foregroundStyle(Paper.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A stretch of time's side of its card: one bar per day (per week for a
/// long stretch), as tall as the photos taken then, so the busy days show.
struct ChapterDensityStrip: View {
    let trip: TimelineTrip

    /// Photo counts from the first day to the last, empty days included.
    static func buckets(for trip: TimelineTrip, calendar: Calendar = .current) -> [Int] {
        let days = trip.days.compactMap { day -> (Date, Int)? in
            guard let date = day.date else { return nil }
            return (calendar.startOfDay(for: date), day.places.reduce(0) { $0 + $1.photoCount })
        }
        guard let first = days.map(\.0).min(), let last = days.map(\.0).max() else { return [] }
        let span = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        let width = span > 90 ? 7 : 1
        var counts = Array(repeating: 0, count: (span + width - 1) / width)
        for (date, count) in days {
            let offset = calendar.dateComponents([.day], from: first, to: date).day ?? 0
            counts[min(offset / width, counts.count - 1)] += count
        }
        return counts
    }

    var body: some View {
        let counts = Self.buckets(for: trip)
        let peak = max(counts.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let gap: CGFloat = counts.count > 40 ? 1 : 2
                let width = max((proxy.size.width - gap * CGFloat(max(counts.count - 1, 0))) / CGFloat(max(counts.count, 1)), 1)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(counts.enumerated()), id: \.offset) { _, count in
                        RoundedRectangle(cornerRadius: min(width / 2, 2), style: .continuous)
                            .fill(count == 0 ? Paper.rule.opacity(0.6) : Paper.accent.opacity(0.35 + 0.5 * Double(count) / Double(peak)))
                            .frame(width: width, height: count == 0 ? 2 : max(4, proxy.size.height * CGFloat(count) / CGFloat(peak)))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            Text(String(localized: "\(trip.itemCount) photos"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Paper.muted)
        }
        .padding(14)
        .background(Paper.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A new chapter: what kind it is (or a tag of one's own), an optional
/// name and its dates, with how many photos it would hold before Create.
struct ChapterNewSheet: View {
    let initialType: ChapterType
    let customTypes: [ChapterType]
    let onCreate: (String, ChapterType, String?, Date, Date) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var type: ChapterType = .trip
    @State private var isCustom = false
    @State private var customLabel = ""
    @State private var customSymbol = "tag"
    @State private var name = ""
    @State private var start = Calendar.current.startOfDay(for: .now)
    @State private var end = Calendar.current.startOfDay(for: .now)
    @State private var members: [TripEdits.Member] = []

    private var chosenType: ChapterType {
        guard isCustom else { return type }
        let label = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? .period : .custom(label)
    }

    private var preview: (joining: Int, elsewhere: Int) {
        let first = TripEdits.dayKey(min(start, end), calendar: .current)
        let last = TripEdits.dayKey(max(start, end), calendar: .current)
        let plan = TripEdits.plan(tripID: "", first: first, last: last, members: members)
        guard chosenType == .trip else {
            // Other chapters take every photo in their dates, locked or not.
            return (members.filter { $0.dayKey.map { first <= $0 && $0 <= last } ?? false }.count, 0)
        }
        return (plan.joining.count, plan.elsewhere.values.reduce(0) { $0 + $1.count })
    }

    var body: some View {
        let preview = self.preview
        VStack(alignment: .leading, spacing: 16) {
            Text("New chapter")
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(Paper.ink)
            typePicker
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if isCustom {
                    GridRow {
                        PaperFormLabel(String(localized: "Tag"))
                        HStack(spacing: 8) {
                            TextField("", text: $customLabel, prompt: Text("Moving house, Exams, Baby's first year…"))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("chapters.new.tag")
                            Picker("", selection: $customSymbol) {
                                ForEach(ChapterType.customSymbols, id: \.self) { symbol in
                                    Image(systemName: symbol).tag(symbol)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .help(String(localized: "Icon"))
                        }
                    }
                }
                GridRow {
                    PaperFormLabel(String(localized: "Name"))
                    TextField("", text: $name, prompt: Text(chosenType == .trip ? LocalizedStringKey("Named after its places if left empty") : LocalizedStringKey("Optional")))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260)
                        .accessibilityIdentifier("trips.new.name")
                }
                GridRow {
                    PaperFormLabel(String(localized: "Starts"))
                    DatePicker("", selection: $start, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("trips.new.start")
                }
                GridRow {
                    PaperFormLabel(String(localized: "Ends"))
                    DatePicker("", selection: $end, in: start..., displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("trips.new.end")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Will add \(preview.joining) · will take out \(0)")
                if preview.elsewhere > 0 {
                    Text("\(preview.elsewhere) in other trips stay there")
                        .foregroundStyle(Paper.muted)
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(Paper.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("trips.new.preview")
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Create")) {
                    onCreate(name, chosenType, isCustom ? customSymbol : nil, start, max(start, end))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCustom && customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("trips.new.create")
            }
        }
        .padding(PaperMetrics.sheetInset)
        .frame(minWidth: 440)
        .background(Paper.canvas)
        .onAppear {
            members = TripEdits.members(context: modelContext)
            if case let .custom(label) = initialType {
                isCustom = true
                customLabel = label
            } else {
                type = initialType
            }
        }
    }

    /// The preset kinds, the tags already used, and "Other…" for a new tag.
    private var typePicker: some View {
        let presets: [(ChapterType?, String, String)] = ChapterType.presets.map { ($0, $0.label, $0.defaultSymbol) }
        let tags: [(ChapterType?, String, String)] = customTypes.map { ($0, $0.label, "tag") }
        let other: [(ChapterType?, String, String)] = [(nil, String(localized: "Other…"), "plus")]
        let options = presets + tags + other
        return FlowChips(options.map { option in
            let isOn: Bool
            if let kind = option.0 {
                if case .custom = kind { isOn = isCustom && chosenType == kind } else { isOn = !isCustom && type == kind }
            } else {
                isOn = isCustom && !customTypes.contains(chosenType)
            }
            return FlowChips.Chip(id: option.0?.raw ?? "other", label: option.1, symbol: option.2, isOn: isOn) {
                if let picked = option.0 {
                    if case let .custom(label) = picked {
                        isCustom = true
                        customLabel = label
                    } else {
                        isCustom = false
                        type = picked
                    }
                } else {
                    isCustom = true
                    customLabel = ""
                }
            }
        })
    }
}

/// Chips that wrap onto more lines when the sheet is narrow.
struct FlowChips: View {
    struct Chip: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let isOn: Bool
        let action: () -> Void
    }

    let chips: [Chip]

    init(_ chips: [Chip]) {
        self.chips = chips
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips) { chip in
                Button(action: chip.action) {
                    Label(chip.label, systemImage: chip.symbol)
                        .font(.callout)
                        .foregroundStyle(chip.isOn ? Paper.raised : Paper.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(chip.isOn ? Paper.accent : Paper.well, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chip.isOn ? .isSelected : [])
                .accessibilityIdentifier("chapters.new.type.\(chip.id)")
            }
        }
    }
}

/// Lays children left to right, starting a new line when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
