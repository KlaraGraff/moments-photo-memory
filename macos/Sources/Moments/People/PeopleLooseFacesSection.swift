import SwiftUI

/// The faces seen only once or twice, gathered at the bottom of the People
/// screen in one collapsed section so they are never asked to be named.
///
/// `DisclosureGroup` builds its content only while the section is expanded, so
/// a collapsed section costs a single label row and decodes no crops.
struct PeopleLooseFacesSection<Menu: View>: View {
    let faces: [FaceObservation]
    @Binding var isExpanded: Bool
    /// The right-click menu for one face (the screen passes its existing correction menu).
    @ViewBuilder let menu: (FaceObservation) -> Menu

    private var title: some View {
        Text("Loose faces")
            .font(.headline)
    }

    private var summary: some View {
        Text("\(faces.count) faces · seen once or twice, no name needed")
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
            ForEach(faces, id: \.id) { face in
                FaceCropView(data: face.cropData, cacheKey: face.id, size: 64)
                    .contextMenu { menu(face) }
            }
        }
    }

    private var hint: some View {
        Text("Right-click a face to give it to a person.")
            .font(.caption)
            .foregroundStyle(Paper.muted)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                grid
                hint
            }
        } label: {
            label
        }
        .paperCard()
        .accessibilityIdentifier("people.loose")
    }
}
