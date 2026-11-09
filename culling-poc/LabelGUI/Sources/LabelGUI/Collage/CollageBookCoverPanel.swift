import SwiftUI
import AppKit

// MARK: - 文档 › 封面（C4 的第 1 波：只读预览 + 书脊、包边、板厚、书脊字、封底、做 / 去掉）
//
// 封面那块的格子、换照片、改字在画布上编辑（store.editingCover，跨页条最前面那张「封面」卡，第 2 波接）；这里管
// 只在检视器里改的：书脊宽（印厂给的数，没填 = 估的）、包边、板厚、每张纸厚、书脊上的字、封底。只在相册时出现。

struct CollageBookCoverBox: View {
    @ObservedObject var store: CollageStore
    @State private var spineTitle = ""
    @State private var spineDate = ""
    @State private var backText = ""
    @State private var thumb: NSImage?

    var body: some View {
        if store.isAlbum {
            GroupBox("封面") {
                VStack(alignment: .leading, spacing: 8) {
                    if let cover = store.project.bookCover {
                        made(cover)
                    } else {
                        Text("精装封面：封底 | 书脊 | 封面一整张，四周包边。主图用扉页那张（没有就挑分数最高、有人脸的），标题、日期照扉页。导出时单独出「名_封面」图和 PDF。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("做封面") { store.makeCover() }
                            .disabled(store.project.photos.isEmpty)
                            .help(store.project.photos.isEmpty ? "托盘是空的：先带照片进来" : "按扉页做一张封面（⌘Z 能撤回）")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    @ViewBuilder
    private func made(_ cover: CollageBookCover) -> some View {
        let spreads = store.project.pages.count
        let estimate = cover.estimatedSpineMM(spreads: spreads)
        preview
        // 书脊宽：印厂给的数。空着 = 按估算（写清楚是估的、怎么估的）。
        HStack(spacing: 4) {
            Text("书脊").font(.caption).frame(width: 52, alignment: .leading)
            CoverMMField(value: cover.spineMM, placeholder: String(format: "估 %.1f", estimate)) { store.setCoverSpine($0) }
            Text("mm").font(.caption).foregroundStyle(.secondary)
            if cover.spineMM != nil {
                Button("用估算") { store.setCoverSpine(nil) }
                    .font(.caption)
                    .help("清掉填的数，按页数估")
            }
        }
        Text(cover.spineMM == nil
             ? String(format: "估的：%dP × 每张纸 %.2f mm ÷ 2 + 两块板 2 × %.1f mm ≈ %.1f mm。照印厂给的书脊宽填进去。",
                      CollageBookCover.pageCount(spreads: spreads), cover.sheetMM, cover.boardMM, estimate)
             : String(format: "填的是印厂给的数（按页数估是 %.1f mm）。", estimate))
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if cover.hasSpineText, !CollageBookCover.spineFitsText(cover.spineWidthMM(spreads: spreads)) {
            Label(String(format: "书脊只有 %.1f mm，放不下字（至少 %.0f mm）：书脊上不印字",
                         cover.spineWidthMM(spreads: spreads), CollageBookCover.minSpineTextMM),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(store.coverFaceWarnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 4) {
            Text("包边").font(.caption).frame(width: 52, alignment: .leading)
            CoverMMField(value: cover.wrapMM, placeholder: "15") { if let v = $0 { store.setCoverWrap(v) } }
            Text("mm").font(.caption).foregroundStyle(.secondary)
            Text("板厚").font(.caption).padding(.leading, 6)
            CoverMMField(value: cover.boardMM, placeholder: "2") { if let v = $0 { store.setCoverBoard(v) } }
            Text("mm").font(.caption).foregroundStyle(.secondary)
        }
        .help("包边：封面纸翻过板边包进去的那一圈（照印厂的模板改）；板厚只用来估书脊")
        HStack(spacing: 4) {
            Text("每张纸").font(.caption).frame(width: 52, alignment: .leading)
            CoverMMField(value: cover.sheetMM, placeholder: "0.15") { if let v = $0 { store.setCoverSheet(v) } }
            Text("mm（一张 = 2P，只用来估书脊）").font(.caption2).foregroundStyle(.secondary)
        }
        Divider()
        Text("书脊上的字").font(.caption.weight(.semibold))
        TextField("标题（{title}；空 = 不印）", text: $spineTitle)
            .onChange(of: spineTitle) { _, v in if v != cover.spineTitle { store.setCoverSpineText(title: v) } }
        TextField("日期（{date}；空 = 不印）", text: $spineDate)
            .onChange(of: spineDate) { _, v in if v != cover.spineDate { store.setCoverSpineText(date: v) } }
        Text("中文从上往下竖排，拉丁字母、数字转 90° 从上往下读。")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        Divider()
        HStack(spacing: 6) {
            Text("封底").font(.caption.weight(.semibold))
            Menu {
                Button("不放照片") { store.setCoverBackPhoto(nil) }
                Divider()
                ForEach(store.coverBackCandidates(), id: \.id) { p in
                    Button(p.id) { store.setCoverBackPhoto(p.id) }
                }
            } label: {
                Text(cover.back.photoID.map { "小照片 \($0)" } ?? "留白（不放照片）").lineLimit(1)
            }
            .help("封底放一张小照片（完整显示），或者留白")
        }
        TextField("封底一行字（空 = 不印）", text: $backText)
            .onChange(of: backText) { _, v in if v != cover.back.text { store.setCoverBackText(v) } }
        Divider()
        HStack {
            Button("按扉页重做") { store.makeCover(replace: true) }
                .help("封面那块按现在的扉页重新出（书脊、包边、封底这些不动）")
            Spacer()
            Button("去掉封面", role: .destructive) { store.removeCover() }
                .help("不做封面了（⌘Z 能撤回）")
        }
        .font(.caption)
        .onAppear { syncFields(cover) }
        .onChange(of: cover) { _, c in syncFields(c) }
    }

    /// 只读预览：整张封面（带包边、出血、折线），后台渲（不在 body 里渲），工程里和封面有关的一变就重渲。
    private var preview: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let thumb {
                Image(nsImage: thumb).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(previewAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .help("只读预览：青线是折线（包边往里折）和书脊，绿虚线是安全区；封面那块的格子、照片、字在画布上编辑")
        .task(id: previewKey) { await renderPreview() }
    }

    private var previewAspect: CGFloat {
        guard let l = store.coverLayout, l.height > 0 else { return 2.2 }
        return CGFloat(l.width) / CGFloat(l.height)
    }

    /// 预览跟着变的（封面、画布、样式、标题、跨页数、封面用到的照片、路人信息和蒙版的版本）：同跨页条的封面卡
    /// （CollageCoverPreview）。
    private var previewKey: Int { CollageCoverPreview.key(store) }

    private func renderPreview() async {
        // 检视器约 300pt 宽：渲 600 像素宽（Retina 两倍）够看清书脊字。
        let image = await CollageCoverPreview.render(store, longEdge: 600, guides: true)
        guard !Task.isCancelled else { return }
        thumb = image
    }

    private func syncFields(_ cover: CollageBookCover) {
        if spineTitle != cover.spineTitle { spineTitle = cover.spineTitle }
        if spineDate != cover.spineDate { spineDate = cover.spineDate }
        if backText != cover.back.text { backText = cover.back.text }
    }
}

/// 毫米数字框：回车或离开时写回（认不出来的数不写、框里回到原来的数）；模型变了（夹到范围里、撤销、ops）跟着变。
/// nil = 空着（书脊 = 按估算）。
private struct CoverMMField: View {
    let value: Double?
    let placeholder: String
    let apply: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onAppear { text = Self.format(value) }
            // 打字的时候模型不变（回车 / 离开才写回）：模型一变就照它显示（夹过范围的数、撤销回去的数）。
            .onChange(of: value) { _, v in text = Self.format(v) }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            apply(nil)
        } else if let v = Double(t), v.isFinite {
            apply(v)
        } else {
            text = Self.format(value)
        }
    }

    static func format(_ v: Double?) -> String {
        guard let v else { return "" }
        let s = String(format: "%.2f", v)
        // 12.50 → 12.5，15.00 → 15
        var trimmed = s
        while trimmed.contains("."), trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}
