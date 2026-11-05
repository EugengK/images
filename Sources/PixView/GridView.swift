import SwiftUI

struct GridView: View {
    @EnvironmentObject var lib: Library
    @FocusState private var focused: Bool

    private func columnCount(_ width: CGFloat) -> Int {
        max(1, Int((width - 24 + 10) / (CGFloat(lib.thumbSize) + 10)))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    if lib.isLoading {
                        ProgressView().padding(40)
                    } else if lib.visibleItems.isEmpty {
                        Text(lib.favoritesOnly ? "즐겨찾기한 이미지가 없습니다" : "이 폴더에 이미지가 없습니다")
                            .foregroundStyle(.secondary).padding(40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(lib.thumbSize)), spacing: 10)],
                              spacing: 10) {
                        ForEach(lib.visibleItems) { item in
                            ThumbCell(item: item,
                                      selected: lib.selection.contains(item.url),
                                      current: lib.current == item.url,
                                      favorite: lib.isFavorite(item.url))
                                .id(item.url)
                                .gesture(TapGesture(count: 2).onEnded {
                                    lib.select(item.url); lib.viewing = true
                                })
                                .simultaneousGesture(TapGesture().onEnded { lib.click(item.url) })
                                .contextMenu {
                                    Button("열기") { lib.select(item.url); lib.viewing = true }
                                    Button(lib.isFavorite(item.url) ? "즐겨찾기 해제" : "즐겨찾기") {
                                        lib.toggleFavorite(lib.selection.contains(item.url) ? lib.targets : [item.url])
                                    }
                                    Button("이름 바꾸기…") { lib.beginRename(item.url) }
                                    Button("이동…") { lib.moveToFolder(lib.selection.contains(item.url) ? lib.targets : [item.url]) }
                                    Button("Finder에서 보기") { lib.revealInFinder([item.url]) }
                                    Divider()
                                    Button("휴지통으로", role: .destructive) {
                                        lib.trash(lib.selection.contains(item.url) ? lib.targets : [item.url])
                                    }
                                }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: lib.current) { _, new in
                    if let new { proxy.scrollTo(new) }
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(phases: [.down, .repeat]) { press in
                let cols = columnCount(geo.size.width)
                let cmd = press.modifiers.contains(.command)
                if press.key == .leftArrow { lib.step(-1); return .handled }
                if press.key == .rightArrow { lib.step(1); return .handled }
                if press.key == .upArrow { lib.step(-cols); return .handled }
                if press.key == .downArrow { lib.step(cols); return .handled }
                if press.key == .return || press.key == .space {
                    if lib.current != nil { lib.viewing = true }
                    return .handled
                }
                if press.key == .delete || press.key == .deleteForward {
                    lib.trash(lib.targets); return .handled
                }
                if cmd && press.characters == "a" { lib.selectAll(); return .handled }
                if !cmd && press.characters == "f" { lib.toggleFavorite(lib.targets); return .handled }
                return .ignored
            }
        }
    }
}

struct ThumbCell: View {
    let item: ImageItem
    let selected: Bool
    let current: Bool
    let favorite: Bool
    @State private var image: NSImage?

    var body: some View {
        Color(nsColor: .underPageBackgroundColor)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.medium).scaledToFit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay(alignment: .topTrailing) {
                if favorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                        .shadow(radius: 2).padding(5)
                }
            }
            .overlay(alignment: .bottom) {
                Text(item.url.lastPathComponent)
                    .font(.caption2).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.45))
                    .foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : (current ? 1.5 : 0))
            )
            .task(id: item.url) {
                image = await ImageLoader.thumbnail(for: item.url, maxPixel: 512)
            }
    }
}
