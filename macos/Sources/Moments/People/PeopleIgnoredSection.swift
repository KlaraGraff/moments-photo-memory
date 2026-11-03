import SwiftUI

/// One ignored group: the hidden, unnamed person "Ignore this group" made, and
/// the face that represents it.
struct PeopleIgnoredGroup: Identifiable {
    let id: String
    let cover: FaceObservation?
}

/// The groups the user ignored, gathered at the very bottom of the People
/// screen in one collapsed section. Right-click a group to restore it.
///
/// `DisclosureGroup` builds its content only while the section is expanded, so
/// a collapsed section costs a single label row and decodes no crops.
struct PeopleIgnoredSection<Menu: View>: View {
    let groups: [PeopleIgnoredGroup]
    @Binding var isExpanded: Bool
    /// Right-click menu for one group (the screen passes its Restore action).
    @ViewBuilder let menu: (PeopleIgnoredGroup) -> Menu

    private var title: some View {
        Text(String(localized: "Ignored"))
            .font(.headline)
    }

    private var summary: some View {
        Text(String(localized: "\(groups.count) groups · not shown above"))
            .font(.callout)
            .foregroundStyle(Paper.muted)
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            title
            summary
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
            ForEach(groups) { group in
                cover(group)
                    .contextMenu { menu(group) }
            }
        }
    }

    @ViewBuilder
    private func cover(_ group: PeopleIgnoredGroup) -> some View {
        if let face = group.cover {
            FaceCropView(data: face.cropData, cacheKey: face.id, size: 56)
        } else {
            Circle()
                .fill(Color.gray.opacity(0.18))
                .frame(width: 56, height: 56)
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            grid
        } label: {
            label
        }
        .paperCard()
        .accessibilityIdentifier("people.ignored")
    }
}
