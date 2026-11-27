import MomentsCore
import SwiftUI

// MARK: - Words

/// The judge's reasons and choices, in the person's words.
enum ChapterJudgeText {
    static func roleName(_ role: PlaceRole) -> String {
        switch role {
        case .home: String(localized: "home")
        case .homeTown: String(localized: "your home town")
        case .work, .formerWork: String(localized: "work")
        case .notTrip: String(localized: "a place you named")
        }
    }

    static func reason(_ reason: JudgeReason) -> String {
        switch reason {
        case .allWorkdays: String(localized: "Only workdays")
        case .weekend: String(localized: "Takes in a weekend")
        case let .workScenes(count, total): String(localized: "\(count) of \(total) photos show work")
        case let .leisureScenes(count, total): String(localized: "\(count) of \(total) photos show free time")
        case .workHours: String(localized: "Photos mostly taken in working hours")
        case .freeHours: String(localized: "Photos mostly taken outside working hours")
        case let .farFromBase(km, role): String(localized: "About \(km) km from \(roleName(role))")
        case let .nearBase(km, role): String(localized: "Only \(km) km from \(roleName(role))")
        case .nearHomeTown: String(localized: "Near your home town")
        case .abroad: String(localized: "Abroad")
        case let .longStay(days): String(localized: "A long stay of \(days) days")
        case let .shortVisit(days): String(localized: "Only \(days) days")
        case .fewPhotos: String(localized: "Few photos each day")
        case .manyPhotos: String(localized: "Many photos each day")
        case let .similar(title, kind, start, _):
            String(localized: "Much like “\(title)” (\(start.formatted(.dateTime.month(.abbreviated).year()))), which you called “\(kind.label)”")
        }
    }

    /// Every reason to show, the model's own first.
    static func reasons(_ verdict: ChapterVerdict) -> [String] {
        var lines: [String] = []
        if let line = verdict.modelReason, !line.isEmpty { lines.append(line) }
        lines += verdict.reasons.prefix(5).map(reason)
        return lines
    }

    /// The one reason in the check line.
    static func shortReason(_ verdict: ChapterVerdict) -> String? {
        if let line = verdict.modelReason, !line.isEmpty { return line }
        return verdict.reasons.first.map(reason)
    }

    static func confidence(_ verdict: ChapterVerdict, action: JudgeAction?) -> String {
        if verdict.source == .person { return String(localized: "You decided this.") }
        switch action {
        case .apply: return String(localized: "Sure enough to sort it without asking.")
        case .applyAndCheck: return String(localized: "Fairly sure, so I sorted it and asked once.")
        case .ask, nil: return String(localized: "Not sure, so I'm asking you.")
        }
    }

    static func askLevel(_ level: AskLevel) -> String {
        switch level {
        case .more: String(localized: "Ask more")
        case .balanced: String(localized: "Balanced")
        case .less: String(localized: "Ask less")
        }
    }

    /// "11.06 – 11.09 · Fri to Mon · 460 km from work"
    static func facts(start: Date?, end: Date?, verdict: ChapterVerdict) -> String {
        var parts: [String] = []
        if let start {
            let end = max(end ?? start, start)
            let formatter = DateIntervalFormatter()
            formatter.dateTemplate = "MMMd"
            parts.append(formatter.string(from: start, to: end))
            let first = start.formatted(.dateTime.weekday(.abbreviated))
            let last = end.formatted(.dateTime.weekday(.abbreviated))
            if !Calendar.autoupdatingCurrent.isDate(start, inSameDayAs: end) {
                parts.append(String(localized: "\(first) to \(last)"))
            }
        }
        for reason in verdict.reasons {
            switch reason {
            case let .farFromBase(km, role), let .nearBase(km, role):
                parts.append(String(localized: "\(km) km from \(roleName(role))"))
            default:
                continue
            }
            break
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Banners above the chapters

/// While the judge looks at the chapters.
struct ChapterJudgeProgressBanner: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(String(localized: "Looking at what each chapter was… \(done) of \(total)"))
                .foregroundStyle(Paper.muted)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chapters.judge.progress")
    }
}

/// Chapters the judge is not sure about.
struct ChapterQuestionBanner: View {
    let count: Int
    let onLook: () -> Void
    let onLater: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.bubble")
                .foregroundStyle(Paper.accent)
                .accessibilityHidden(true)
            Text(String(localized: "\(count) chapters I'm not sure about. Can I ask you?"))
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(String(localized: "Take a look"), action: onLook)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("chapters.judge.banner.look")
            Button(String(localized: "Not now"), action: onLater)
                .accessibilityIdentifier("chapters.judge.banner.later")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Paper.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chapters.judge.banner")
    }
}

// MARK: - Asking

/// One chapter to ask about.
struct ChapterQuestion: Identifiable {
    let id: String
    /// The city the photos were taken in, if they say.
    let place: String?
    let photos: [MediaItem]
    let facts: String
    let verdict: ChapterVerdict
    /// The guess first, then the other kinds the judge weighed.
    let options: [ChapterKind]
}

/// Asks about the unsure chapters one at a time: what were these days?
struct ChapterAskSheet: View {
    let questions: [ChapterQuestion]
    /// The answer; false when a typed kind could not be kept.
    let onAnswer: (ChapterQuestion, ChapterKind) -> Bool
    let onLater: (ChapterQuestion) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var isTyping = false
    @State private var typed = ""
    @State private var typedFailed = false
    @State private var isShowingWhy = false

    private var question: ChapterQuestion? { questions.indices.contains(index) ? questions[index] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let question {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(question.place.map { String(localized: "What were these days in \($0)?") } ?? String(localized: "What were these days?"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Paper.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: "\(index + 1) / \(questions.count)")
                        .foregroundStyle(Paper.muted)
                        .monospacedDigit()
                }
                HStack(spacing: 5) {
                    ForEach(question.photos.prefix(4), id: \.id) { item in
                        ThumbnailView(item: item, width: 96, height: 76)
                            .frame(maxWidth: .infinity)
                            .frame(height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .accessibilityHidden(true)
                Text(question.facts)
                    .foregroundStyle(Paper.muted)
                    .monospacedDigit()
                if isTyping { typing(question) } else { choices(question) }
                HStack {
                    Button(String(localized: "Why ask")) { isShowingWhy = true }
                        .buttonStyle(.link)
                        .font(.callout)
                        .popover(isPresented: $isShowingWhy, arrowEdge: .bottom) {
                            ChapterWhyView(kind: question.verdict.kind, verdict: question.verdict, action: .ask, choices: [], onChange: { _ in })
                        }
                        .accessibilityIdentifier("chapters.ask.why")
                    Spacer()
                    Button(String(localized: "Not now")) {
                        onLater(question)
                        next()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Paper.muted)
                    .accessibilityIdentifier("chapters.ask.later")
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Paper.raised)
        .accessibilityIdentifier("chapters.ask")
    }

    private func choices(_ question: ChapterQuestion) -> some View {
        // The guess, the next likeliest kinds and ordinary days: three
        // answers and "Other…" in a 2 × 2 grid.
        let guess = question.options.first ?? .trip
        let others = question.options.dropFirst().filter { $0 != .daily && $0 != guess }
        let kinds = guess == .daily ? [guess] + Array(others.prefix(2)) : [guess] + Array(others.prefix(1)) + [.daily]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(Array(kinds.enumerated()), id: \.element) { position, kind in
                choice(kind.label, isGuess: position == 0, id: kind.key) { answer(question, kind) }
            }
            choice(String(localized: "Other…"), isGuess: false, id: "other") {
                typed = ""
                typedFailed = false
                isTyping = true
            }
        }
    }

    private func choice(_ title: String, isGuess: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(isGuess ? .semibold : .regular)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .padding(.horizontal, 12)
                .foregroundStyle(isGuess ? Color.white : Paper.ink)
                .background(isGuess ? Paper.accent : Paper.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chapters.ask.choice.\(id)")
    }

    private func typing(_ question: ChapterQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(String(localized: "A kind, like Project visit"), text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveTyped(question) }
                    .accessibilityIdentifier("chapters.ask.typed")
                Button(String(localized: "Save")) { saveTyped(question) }
                    .buttonStyle(.borderedProminent)
                    .disabled(ChapterKind.cleanLabel(typed) == nil)
                Button(String(localized: "Back")) { isTyping = false }
            }
            if typedFailed {
                Text(String(localized: "That can't be a kind. Try a few words."))
                    .font(.callout)
                    .foregroundStyle(Paper.accent)
            }
        }
    }

    private func saveTyped(_ question: ChapterQuestion) {
        guard let label = ChapterKind.cleanLabel(typed) else { typedFailed = true; return }
        answer(question, .custom(label))
    }

    private func answer(_ question: ChapterQuestion, _ kind: ChapterKind) {
        guard onAnswer(question, kind) else { typedFailed = true; return }
        next()
    }

    private func next() {
        isTyping = false
        typedFailed = false
        if index + 1 < questions.count { index += 1 } else { dismiss() }
    }
}

// MARK: - Why, and changing the kind

/// Why the chapter is the kind it is, and the other kinds to pick.
struct ChapterWhyView: View {
    let kind: ChapterKind
    let verdict: ChapterVerdict
    let action: JudgeAction?
    /// The kinds offered to change to; empty to only explain.
    let choices: [ChapterKind]
    let onChange: (ChapterKind) -> Void
    @State private var isTyping = false
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Why “\(kind.label)”"))
                .font(.headline)
                .foregroundStyle(Paper.ink)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ChapterJudgeText.reasons(verdict), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•").foregroundStyle(Paper.muted)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(ChapterJudgeText.confidence(verdict, action: action))
                .font(.callout)
                .foregroundStyle(Paper.muted)
            if !choices.isEmpty {
                Text(String(localized: "Change to")).fontWeight(.semibold)
                if isTyping {
                    HStack(spacing: 6) {
                        TextField(String(localized: "A kind, like Project visit"), text: $typed)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveTyped)
                        Button(String(localized: "Save"), action: saveTyped)
                            .disabled(ChapterKind.cleanLabel(typed) == nil)
                    }
                } else {
                    ChapterChipRow {
                        ForEach(choices, id: \.self) { choice in
                            chip(choice == .daily ? String(localized: "Daily life, not a chapter") : choice.label) { onChange(choice) }
                        }
                        chip(String(localized: "Another kind…")) { isTyping = true }
                    }
                }
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(width: 400, alignment: .leading)
        .background(Paper.raised)
        .accessibilityIdentifier("chapters.why")
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .foregroundStyle(Paper.ink)
                .background(Paper.well, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func saveTyped() {
        guard let label = ChapterKind.cleanLabel(typed) else { return }
        onChange(.custom(label))
    }
}

/// Chips that wrap onto the next line.
struct ChapterChipRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ChipFlow(spacing: 6) { content }
    }

    private struct ChipFlow: Layout {
        let spacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            arrange(width: proposal.width ?? .infinity, subviews: subviews).size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let placed = arrange(width: bounds.width, subviews: subviews)
            for (subview, point) in zip(subviews, placed.points) {
                subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
            }
        }

        private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
            var points: [CGPoint] = []
            var x: CGFloat = 0
            var y: CGFloat = 0
            var line: CGFloat = 0
            var widest: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > 0, x + size.width > width {
                    x = 0
                    y += line + spacing
                    line = 0
                }
                points.append(CGPoint(x: x, y: y))
                x += size.width + spacing
                line = max(line, size.height)
                widest = max(widest, x - spacing)
            }
            return (CGSize(width: widest, height: y + line), points)
        }
    }
}

/// The kind a judged chapter shows on its page; opens why and lets it change.
struct ChapterKindTag: View {
    let kind: ChapterKind
    let verdict: ChapterVerdict
    let action: JudgeAction?
    let choices: [ChapterKind]
    let onChange: (ChapterKind) -> Void
    @State private var isShowingWhy = false

    var body: some View {
        Button { isShowingWhy = true } label: {
            HStack(spacing: 3) {
                Text(kind.label)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .foregroundStyle(Paper.ink)
            .background(Paper.well, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Why this kind"))
        .accessibilityLabel(String(localized: "Chapter kind: \(kind.label)"))
        .accessibilityIdentifier("chapters.kind.tag")
        .popover(isPresented: $isShowingWhy, arrowEdge: .bottom) {
            ChapterWhyView(kind: kind, verdict: verdict, action: action, choices: choices) { choice in
                isShowingWhy = false
                onChange(choice)
            }
        }
    }
}

/// The one-line check on a chapter the judge was fairly sure about.
struct ChapterCheckBar: View {
    let kind: ChapterKind
    let verdict: ChapterVerdict
    let choices: [ChapterKind]
    let onRight: () -> Void
    let onChange: (ChapterKind) -> Void
    @State private var isShowingWhy = false
    @State private var isChanging = false

    private var line: String {
        if let reason = ChapterJudgeText.shortReason(verdict) {
            return String(localized: "I sorted this as “\(kind.label)”: \(reason). Right?")
        }
        return String(localized: "I sorted this as “\(kind.label)”. Right?")
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(line)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(String(localized: "Right"), action: onRight)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("chapters.check.right")
            Button(String(localized: "Change to…")) { isChanging = true }
                .accessibilityIdentifier("chapters.check.change")
                .popover(isPresented: $isChanging, arrowEdge: .bottom) {
                    ChapterWhyView(kind: kind, verdict: verdict, action: .applyAndCheck, choices: choices) { choice in
                        isChanging = false
                        onChange(choice)
                    }
                }
            Button(String(localized: "Why")) { isShowingWhy = true }
                .buttonStyle(.link)
                .accessibilityIdentifier("chapters.check.why")
                .popover(isPresented: $isShowingWhy, arrowEdge: .bottom) {
                    ChapterWhyView(kind: kind, verdict: verdict, action: .applyAndCheck, choices: [], onChange: { _ in })
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.rule))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chapters.check")
    }
}

// MARK: - Settings

struct ChapterJudgeSettingsSection: View {
    @State private var book = ChapterJudgeStore.book()
    /// Read when Settings shows, and again when the AI choice changes.
    @State private var engine = ChapterJudgeEngine.current()
    @AppStorage(AISettings.enabledKey) private var aiEnabled = true
    @AppStorage(AISettings.engineKey) private var aiEngine = AISettings.defaultEngine.rawValue
    @AppStorage(AISettings.modelKey) private var aiModel = ""
    @AppStorage(AISettings.providerKey) private var aiProvider = ""
    @AppStorage(AISettings.baseURLKey) private var aiBaseURL = ""

    private var modelStatus: String {
        switch engine {
        case .onDevice: String(localized: "On this Mac · ready")
        case .cloud: String(localized: "Your cloud model")
        case .rules: String(localized: "No model · rules only")
        }
    }

    var body: some View {
        Group {
            Section {
                Toggle(isOn: Binding(get: { book.enabled }, set: { value in change { $0.enabled = value } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Sort chapters by kind on their own"))
                        Text(String(localized: "Chooses from the built-in kinds and the ones you typed."))
                            .font(.callout)
                            .foregroundStyle(Paper.muted)
                    }
                }
                .accessibilityIdentifier("settings.judge.enabled")
                LabeledContent(String(localized: "Model")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(modelStatus)
                        Text(String(localized: "Uses the same model as AI above."))
                            .font(.callout)
                            .foregroundStyle(Paper.muted)
                    }
                }
                Picker(String(localized: "When unsure"), selection: Binding(get: { book.askLevel }, set: { value in change { $0.askLevel = value } })) {
                    ForEach(AskLevel.allCases, id: \.self) { level in
                        Text(ChapterJudgeText.askLevel(level)).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!book.enabled)
                .accessibilityIdentifier("settings.judge.ask")
            } header: {
                Text(String(localized: "Chapter kinds"))
            }
            Section {
                if book.examples.isEmpty {
                    Text(String(localized: "Nothing learned yet."))
                        .foregroundStyle(Paper.muted)
                }
                ForEach(book.examples) { example in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(example.title) → \(example.kind.label)")
                            Text(verbatim: [
                                DateIntervalFormatter.chapterDays.string(from: example.evidence.start, to: max(example.evidence.end, example.evidence.start)),
                                example.corrected ? String(localized: "You changed it") : String(localized: "You confirmed it"),
                            ].joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(Paper.muted)
                            .monospacedDigit()
                        }
                        Spacer()
                        Button(String(localized: "Delete")) { change { $0.forgetExample(example.id) } }
                            .accessibilityIdentifier("settings.judge.forget")
                    }
                }
            } header: {
                Text(String(localized: "Learned (\(book.examples.count))"))
            } footer: {
                Text(String(localized: "For each chapter only a short text is kept: its dates, weekdays and times, how many photos it has, how far it was from home, work or home town and whether it was abroad, roughly what the photos show, the city and the chapter's title. No photos. With the on-device model nothing leaves this Mac. With a cloud model only that text is sent, together with a few of your earlier answers written the same way and the kinds you named yourself, without photos or coordinates, and without the names of your home, work or home town. Deleting an entry leaves your chapters as they are; it is only no longer used."))
                    .foregroundStyle(Paper.muted)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDecisionChanged)) { note in
            guard note.object as? String == ChapterJudgeStore.key else { return }
            book = ChapterJudgeStore.book()
        }
        .task(id: "\(aiEnabled)|\(aiEngine)|\(aiModel)|\(aiProvider)|\(aiBaseURL)") {
            // Read a moment later, once the AI settings above have saved.
            try? await Task.sleep(for: .milliseconds(300))
            engine = ChapterJudgeEngine.current()
        }
    }

    private func change(_ edit: (inout ChapterJudgeBook) -> Void) {
        book = ChapterJudgeStore.change(edit)
    }
}

extension DateIntervalFormatter {
    /// "Jun 3 – 4, 2026"
    static let chapterDays: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
