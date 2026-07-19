import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: LabelStore

    var body: some View {
        List(selection: Binding(
            get: { store.currentPhoto?.id },
            set: { newId in
                if let newId, let idx = store.photos.firstIndex(where: { $0.id == newId }) {
                    store.goTo(idx)
                }
            }
        )) {
            ForEach(Array(store.photos.enumerated()), id: \.element.id) { index, photo in
                HStack {
                    ThumbnailView(path: photo.previewPath)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading) {
                        Text(photo.id).font(.caption).lineLimit(1)
                        if let g = store.layer1(for: photo.id)?.burstGroup {
                            Text("组 \(g)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if store.binding(for: photo.id).isComplete {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .tag(photo.id)
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }
}

