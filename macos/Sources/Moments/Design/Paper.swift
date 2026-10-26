import SwiftUI

/// The B1 warm-paper palette, shared by every screen and sheet.
///
/// Layers are told apart by tone, not by lines: each surface differs from the
/// one it sits on by only 1-3% lightness. Nothing is pure black; separators
/// are ink at a few percent, used only where a tone change can't do the job.
/// The app is light only. A future dark variant should also drop body text one
/// weight step, because light text on dark reads 10-15% heavier.
enum Paper {
    /// Window content, the base layer.
    static let canvas = Color(red: 0.984, green: 0.945, blue: 0.918)
    static let content = canvas
    /// The sidebar: one step darker than the canvas.
    static let sidebar = Color(red: 0.969, green: 0.906, blue: 0.863)
    /// Cards, panels and focused fields: ~1.5% lighter than the canvas.
    static let raised = Color(red: 0.993, green: 0.973, blue: 0.957)
    /// Resting fields, chips and grouped rows: ~2.5% darker than the canvas.
    static let well = Color(red: 0.961, green: 0.918, blue: 0.886)
    /// A well under the pointer or pressed.
    static let wellHover = Color(red: 0.945, green: 0.898, blue: 0.863)

    static let ink = Color(red: 0.227, green: 0.165, blue: 0.141)
    static let muted = Color(red: 0.478, green: 0.365, blue: 0.314)
    static let accent = Color(red: 0.690, green: 0.290, blue: 0.184)
    /// Hairline separator for the rare place a tone change is not enough.
    static let line = Color(red: 0.937, green: 0.855, blue: 0.796)
    /// The ruled note line under a photo.
    static let rule = Color(red: 0.902, green: 0.804, blue: 0.741)
    /// Shadow colour: warm ink, never black.
    static let shadow = Color(red: 0.227, green: 0.165, blue: 0.141)
}

typealias LibraryPalette = Paper

// MARK: - Motion

/// Motion has a character per kind of interaction: dragging, snapping and
/// expanding settle at once without overshoot; confirmations get one small,
/// friendly bounce. Every helper honours Reduce Motion.
enum Motion {
    /// Drag release, snapping, panels and disclosure: fast, no bounce.
    static let snap = Animation.snappy(duration: 0.22, extraBounce: 0)
    /// Focus, hover and tone changes.
    static let settle = Animation.easeOut(duration: 0.16)
    /// Success feedback such as a checkmark: a little spring.
    static let pop = Animation.spring(response: 0.32, dampingFraction: 0.58)
    /// How long a transient confirmation stays before it hides itself.
    static let confirmationLifetime: Duration = .milliseconds(2500)

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Fields and focus

extension View {
    /// The soft focus treatment: instead of a bright outline the edge and a
    /// faint halo around the field both deepen, like the field settling in.
    func paperFocusRing(_ focused: Bool, cornerRadius: CGFloat = 7) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .overlay(shape.strokeBorder(Paper.ink.opacity(focused ? 0.20 : 0.06), lineWidth: 1))
            .background(
                shape
                    .stroke(Paper.accent.opacity(focused ? 0.13 : 0), lineWidth: 6)
                    .blur(radius: 1)
            )
            .shadow(color: Paper.shadow.opacity(focused ? 0.10 : 0.03), radius: focused ? 3 : 1, y: 1)
    }
}

/// Text field on a well, lifting to the raised tone with the soft focus ring
/// when it has focus. The system's blue focus outline is turned off.
struct PaperFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        PaperField(content: configuration)
    }
}

private struct PaperField<Content: View>: View {
    let content: Content
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(focused ? Paper.raised : Paper.well)
            )
            .paperFocusRing(focused)
            .focusEffectDisabled()
            .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: focused)
    }
}

extension TextFieldStyle where Self == PaperFieldStyle {
    static var paper: PaperFieldStyle { PaperFieldStyle() }
}

// MARK: - Surfaces

extension View {
    /// A chip or pill resting on a well; no outline.
    func paperChip(selected: Bool = false) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Paper.accent.opacity(0.10) : Paper.well, in: Capsule())
    }

    /// A card one step lighter than what it sits on, lifted by a soft warm
    /// shadow instead of a border.
    func paperCard(cornerRadius: CGFloat = 12, padding: CGFloat = 14, selected: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .padding(padding)
            .background(selected ? Paper.accent.opacity(0.07) : Paper.raised, in: shape)
            .overlay(shape.strokeBorder(Paper.accent.opacity(selected ? 0.28 : 0), lineWidth: 1))
            .shadow(color: Paper.shadow.opacity(0.05), radius: 1, y: 1)
            .shadow(color: Paper.shadow.opacity(0.04), radius: 8, y: 3)
    }

    /// A floating panel over a map: raised and opaque, with a two-layer
    /// warm shadow.
    func paperFloatingPanel(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Paper.raised, in: shape)
            .shadow(color: Paper.shadow.opacity(0.10), radius: 1.5, y: 1)
            .shadow(color: Paper.shadow.opacity(0.14), radius: 14, y: 6)
    }

    /// A group of rows set into the surface, a little darker than around it.
    func paperWell(cornerRadius: CGFloat = 10, padding: CGFloat = 10) -> some View {
        self
            .padding(padding)
            .background(Paper.well.opacity(0.75), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Screen header

/// The serif title every list screen opens with, at one fixed position so
/// switching screens never moves it.
struct PaperScreenHeader<Detail: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(title)
                    .font(PaperMetrics.screenTitleFont)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                detail
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Paper.muted)
            }
            .fixedSize()
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, PaperMetrics.screenInset)
        .padding(.top, PaperMetrics.screenTopInset)
        .padding(.bottom, 18)
    }
}

extension PaperScreenHeader where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder detail: () -> Detail) {
        self.init(title, detail: detail, trailing: { EmptyView() })
    }
}

extension PaperScreenHeader where Detail == EmptyView, Trailing == EmptyView {
    init(_ title: String) {
        self.init(title, detail: { EmptyView() }, trailing: { EmptyView() })
    }
}

enum PaperMetrics {
    /// Leading and trailing inset of every list screen.
    static let screenInset: CGFloat = 34
    /// Space between the title bar and a screen's first row.
    static let screenTopInset: CGFloat = 16
    static let screenTitleFont = Font.system(size: 34, weight: .medium, design: .serif)
    /// Sheets: the same inset on every side and between header, body and footer.
    static let sheetInset: CGFloat = 24
}

// MARK: - Sheets

/// The shell for every sheet: a serif title with an optional line under it,
/// the body, and a footer of buttons set on a slightly darker band. Keeps
/// every sheet's edges, title and buttons in the same places.
struct PaperSheet<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                    .foregroundStyle(Paper.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(Paper.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, PaperMetrics.sheetInset)
            .padding(.top, 22)
            .padding(.bottom, 16)

            content
                .padding(.horizontal, PaperMetrics.sheetInset)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                footer
            }
            .controlSize(.large)
            .padding(.horizontal, PaperMetrics.sheetInset)
            .padding(.vertical, 14)
            .background(Paper.well.opacity(0.6))
        }
        .background(Paper.canvas)
        .foregroundStyle(Paper.ink)
        .tint(Paper.accent)
    }
}

/// A label in a sheet's form column. Labels sit right-aligned against the
/// controls, on the controls' first text baseline (use inside a `Grid`).
struct PaperFormLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(Paper.muted)
            .lineLimit(1)
            .fixedSize()
            .gridColumnAlignment(.trailing)
    }
}

// MARK: - Inline icons

extension View {
    /// An SF Symbol beside text in a centre-aligned row: its centre is nudged
    /// down an eighth of the text height so it lines up with the letters
    /// instead of floating above them. (In first-baseline rows symbols already
    /// sit on the baseline and need no nudge.)
    func inlineIcon() -> some View {
        modifier(InlineIconOffset())
    }
}

private struct InlineIconOffset: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var textHeight: CGFloat = 13

    func body(content: Content) -> some View {
        content.alignmentGuide(VerticalAlignment.center) { dimensions in
            dimensions[VerticalAlignment.center] - textHeight / 8
        }
    }
}

// MARK: - Transient confirmation

/// A small checkmark that pops in with a slight bounce and hides itself after
/// 2.5 seconds. Increment `trigger` to show it.
struct TransientCheckmark: View {
    let trigger: Int
    var label: String? = nil
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
            if let label { Text(label) }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Paper.accent)
        .scaleEffect(visible || reduceMotion ? 1 : 0.6)
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(!visible)
        .task(id: trigger) {
            guard trigger > 0 else { return }
            withAnimation(Motion.animation(Motion.pop, reduceMotion: reduceMotion)) { visible = true }
            try? await Task.sleep(for: Motion.confirmationLifetime)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) { visible = false }
        }
    }
}

// MARK: - Ink reveal

/// AI-written text arrives like ink on paper: each word starts blurred and
/// transparent and comes into focus, neighbours a few dozen milliseconds
/// apart, so the line resolves as a soft wave. Plays once per `id`.
struct InkRevealText: View {
    let text: String
    @State private var progress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if #available(macOS 15.0, *) {
            Text(text)
                .textRenderer(InkRevealRenderer(progress: progress))
                .onAppear { play() }

        } else {
            Text(text)
                .blur(radius: (1 - progress) * 4)
                .opacity(progress)
                .onAppear { play() }
        }
    }

    private func play() {
        guard !reduceMotion else {
            progress = 1
            return
        }
        let duration = min(0.35 + Double(text.count) * 0.018, 1.4)
        withAnimation(.easeOut(duration: duration)) { progress = 1 }
    }
}

@available(macOS 15.0, *)
private struct InkRevealRenderer: TextRenderer, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// Fraction of the whole reveal each glyph run takes to come into focus.
    private let window = 0.35

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run.map { $0 } } }
        let count = max(slices.count, 1)
        for (index, slice) in slices.enumerated() {
            let start = Double(index) / Double(count) * (1 - window)
            let local = min(max((progress - start) / window, 0), 1)
            var copy = context
            copy.opacity = local
            if local < 1 {
                copy.addFilter(.blur(radius: (1 - local) * 5))
            }
            copy.draw(slice)
        }
    }
}
