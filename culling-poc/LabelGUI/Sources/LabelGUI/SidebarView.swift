import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: LabelStore

    private var visiblePhotos: [Photo] {
        store.showOnlyUnlabeled ? store.photos.filter { !store.isComplete($0.id) } : store.photos
    }

    var body: some View {
        List(selection: Binding(
            get: { store.currentPhoto?.id },
            set: { newId in
                if let newId, let idx = store.photos.firstIndex(where: { $0.id == newId }) {
                    store.goTo(idx)
                }
            }
        )) {
            ForEach(visiblePhotos) { photo in
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
                    if store.isComplete(photo.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .tag(photo.id)
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("只看未标注", isOn: $store.showOnlyUnlabeled)
                .toggleStyle(.checkbox)
            Button {
                store.nextUnlabeled()
            } label: {
                Label("下一张未标注  ⌘]", systemImage: "arrow.right.to.line")
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(store.photos.isEmpty || store.labeledCount == store.photos.count)
            if let error = store.saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.bar)
    }
}
