import SwiftUI

/// What sits under one of the two faces on a "same person?" card.
enum PeopleQuestionCaption: Equatable {
    /// A person who already has a name.
    case named(String)
    /// A cluster without a name yet, with how many faces it holds.
    case unnamed(Int)
}

/// One yes/no question at a time: two faces side by side, a caption under
/// each, the three answers and how many questions are left.
///
/// Kept in its own file and view so answering a question redraws only this
/// card, not the whole People page. The caller builds the faces.
struct PeopleQuestionCard<Left: View, Right: View>: View {
    let leftCaption: PeopleQuestionCaption
    let rightCaption: PeopleQuestionCaption
    /// Live questions after this one; the counter is hidden when 0.
    let remaining: Int
    let onSame: () -> Void
    let onDifferent: () -> Void
    let onSkip: () -> Void
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title
            card
        }
    }

    private var title: some View {
        Text("Are these two the same person?")
            .font(.title3)
    }

    private var card: some View {
        HStack(spacing: 12) {
            faceColumn(caption: leftCaption, face: left)
            equalsMark
            faceColumn(caption: rightCaption, face: right)
            buttons
            Spacer()
            counter
        }
        .paperCard()
        .accessibilityIdentifier("people.question")
    }

    private var equalsMark: some View {
        Text("=?").foregroundStyle(Paper.muted)
    }

    private func faceColumn<Face: View>(
        caption: PeopleQuestionCaption,
        @ViewBuilder face: () -> Face
    ) -> some View {
        VStack(spacing: 6) {
            face()
            PeopleQuestionCaptionLabel(caption: caption)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Same person", action: onSame)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("people.question.same")
            Button("No", action: onDifferent)
                .accessibilityIdentifier("people.question.no")
            Button("Skip for now", action: onSkip)
                .accessibilityIdentifier("people.question.skip")
        }
    }

    @ViewBuilder
    private var counter: some View {
        if remaining > 0 {
            Text("\(remaining) questions left")
                .font(.callout)
                .foregroundStyle(Paper.muted)
        }
    }
}

/// The caption under one face: the name, or the face count of an unnamed
/// cluster. Both are one muted line.
private struct PeopleQuestionCaptionLabel: View {
    let caption: PeopleQuestionCaption

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(Paper.muted)
    }

    private var text: Text {
        switch caption {
        case .named(let name):
            return Text("Named: \(name)")
        case .unnamed(let count):
            return Text("Unnamed · \(count) faces")
        }
    }
}
