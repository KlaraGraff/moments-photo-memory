import MomentsCore
import SwiftData
import SwiftUI

extension View {
    /// Two sheets of paper peeking out above a stacked photo, so a burst
    /// reads as a pile at a glance. In the dense grid the sheets shrink to
    /// thin edges, so the rows stay calm.
    func stackedPaper(_ count: Int, isCompact: Bool, cornerRadius: CGFloat = 0) -> some View {
        modifier(StackedPaperEdges(isStacked: count > 1, isCompact: isCompact, cornerRadius: cornerRadius))
    }
}

private struct StackedPaperEdges: ViewModifier {
    let isStacked: Bool
    let isCompact: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            if isStacked {
                ZStack {
                    sheet(level: 2, tone: Paper.well)
                    sheet(level: 1, tone: Paper.raised)
                }
            }
        }
    }

    private func sheet(level: CGFloat, tone: Color) -> some View {
        let inset = (isCompact ? 5 : 9) * level
        let lift = (isCompact ? 2 : 4) * level
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tone)
            .shadow(color: Paper.shadow.opacity(isCompact ? 0.10 : 0.08), radius: isCompact ? 0.5 : 1.5, y: 0.5)
            .padding(.horizontal, inset)
            .offset(y: -lift)
            .accessibilityHidden(true)
    }
}

/// How many photos a stack holds, in its corner.
struct StackCountBadge: View {
    let count: Int
    var isCompact = false

    var body: some View {
        HStack(spacing: 3) {
            if !isCompact {
                Image(systemName: "square.stack")
                    .font(.caption2.weight(.semibold))
            }
            Text(verbatim: "\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, isCompact ? 5 : 7)
        .padding(.vertical, 2)
        .background(Paper.shadow.opacity(0.58), in: Capsule())
        .padding(isCompact ? 5 : 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Stack of \(count) photos"))
    }
}

/// Under the photo in the large viewer: every shot of the stack, oldest
/// first, like the burst picker in Photos. The open one has the accent
/// frame; the cover carries a small star.
struct ViewerStackStrip: View {
    let stack: PhotoStack
    let members: [MediaItem]
    let currentID: String
    let select: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(members.enumerated()), id: \.element.id) { offset, item in
                            thumb(item, position: offset + 1)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    // Centred while the stack is narrower than the card; a
                    // long stack scrolls sideways in a small window.
                    .frame(minWidth: geometry.size.width)
                }
                .onChange(of: currentID, initial: true) { _, id in
                    if reduceMotion {
                        proxy.scrollTo(id, anchor: .center)
                    } else {
                        withAnimation(Motion.snap) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(height: 70)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer.stack")
    }

    private func thumb(_ item: MediaItem, position: Int) -> some View {
        let isCurrent = item.id == currentID
        let isCover = item.id == stack.coverID
        return Button {
            select(item.id)
        } label: {
            ThumbnailView(item: item, width: 120, height: 120)
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isCurrent ? LibraryPalette.accent : Paper.shadow.opacity(0.06), lineWidth: isCurrent ? 2.5 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isCover {
                        Image(systemName: "star.circle.fill")
                            .font(.caption)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, LibraryPalette.accent)
                            .padding(2)
                    }
                }
                .opacity(isCurrent ? 1 : 0.82)
                .scaleEffect(isCurrent ? 1 : 0.92)
                .animation(reduceMotion ? nil : Motion.snap, value: isCurrent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCover ? String(localized: "Cover photo") : String(localized: "Show this photo"))
        .accessibilityLabel(String(localized: "Photo \(position) of \(members.count)"))
        // Like the grid's "Selected": a fixed value tests can read.
        .accessibilityValue([isCurrent ? "Current" : nil, isCover ? "Cover" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("viewer.stack.\(item.id)")
    }
}

/// "Cover changed · Undo" after a change to a stack; hides itself.
struct StackChangeUndoBar: View {
    @Environment(PhotoStackModel.self) private var stacks
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let change = stacks.lastChange {
            HStack(spacing: 10) {
                Text(message(change.kind))
                    .foregroundStyle(LibraryPalette.ink)
                Button(String(localized: "Undo")) {
                    // Undone here, so ⌘Z must not undo it a second time.
                    undoManager?.removeAllActions(withTarget: change.undoTarget)
                    stacks.undo(change, context: modelContext)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(LibraryPalette.accent)
                .accessibilityIdentifier("viewer.stack.undo")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Paper.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Paper.shadow.opacity(0.08)))
            .shadow(color: Paper.shadow.opacity(0.12), radius: 8, y: 2)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .task(id: change.id) {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, stacks.lastChange == change else { return }
                withAnimation(reduceMotion ? nil : Motion.settle) { stacks.dismissLastChange() }
            }
        }
    }

    private func message(_ kind: PhotoStackModel.Change.Kind) -> String {
        switch kind {
        case .cover: return String(localized: "Cover changed")
        case .unstack: return String(localized: "Stack taken apart")
        case .remove: return String(localized: "Removed from the stack")
        }
    }
}
