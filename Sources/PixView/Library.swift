import SwiftUI
import AppKit

struct ImageItem: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let size: Int
    var id: URL { url }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "이름", date = "수정일", size = "용량"
    var id: String { rawValue }
}

@MainActor
final class Library: ObservableObject {
    @Published var folder: URL?
    @Published var items: [ImageItem] = []
    @Published var subfolders: [URL] = []
    @Published var selection: Set<URL> = []
    @Published var current: URL?
    @Published var viewing = false
    @Published var isLoading = false
    @Published var busy = false
    @Published var message: String?
    @Published var thumbSize: Double = 170
    @Published var favoritesOnly = false
    @Published var sortKey: SortKey = .name { didSet { sortItems() } }
    @Published var ascending = true { didSet { sortItems() } }
    @Published var favorites: Set<String> {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites") }
    }
    @Published var showRename = false
    @Published var renameText = ""

    private var renameTarget: URL?
    private var messageTask: Task<Void, Never>?

    init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    }

    // MARK: 목록

    var visibleItems: [ImageItem] {
        favoritesOnly ? items.filter { favorites.contains($0.url.path) } : items
    }

    /// 현재 선택된 파일들 (선택이 없으면 현재 파일)
    var targets: [URL] {
        if selection.isEmpty { return current.map { [$0] } ?? [] }
        return visibleItems.filter { selection.contains($0.url) }.map(\.url)
    }

    func isFavorite(_ u: URL) -> Bool { favorites.contains(u.path) }

    func sortItems() {
        items.sort { a, b in
            let c: ComparisonResult
            switch sortKey {
            case .name:
                c = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
            case .date:
                c = a.modified.compare(b.modified)
            case .size:
                c = a.size < b.size ? .orderedAscending : (a.size > b.size ? .orderedDescending : .orderedSame)
            }
            if c == .orderedSame { return a.url.path < b.url.path }
            return ascending ? c == .orderedAscending : c == .orderedDescending
        }
    }

    // MARK: 열기

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "열기"
        if p.runModal() == .OK, let u = p.url { load(folder: u) }
    }

    func open(url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue { load(folder: url) }
        else { load(folder: url.deletingLastPathComponent(), select: url, view: true) }
    }

    func goUp() {
        guard let f = folder, f.path != "/" else { return }
        load(folder: f.deletingLastPathComponent())
    }

    func reload() { if let f = folder { load(folder: f, select: current) } }

    func load(folder: URL, select: URL? = nil, view: Bool = false) {
        self.folder = folder
        items = []; subfolders = []; selection = []; current = nil; viewing = false
        isLoading = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { ImageFiles.scan(folder) }.value
            guard self.folder == folder else { return }
            items = r.items
            subfolders = r.subfolders
            isLoading = false
            sortItems()
            var target = items.first?.url
            if let s = select,
               let hit = items.first(where: { $0.url.standardizedFileURL == s.standardizedFileURL }) {
                target = hit.url
            }
            current = target
            if let t = target { selection = [t] }
            viewing = view && target != nil
        }
    }

    // MARK: 선택·이동

    func select(_ u: URL) { current = u; selection = [u] }

    func selectAll() { selection = Set(visibleItems.map(\.url)) }

    func click(_ u: URL) {
        let flags = NSEvent.modifierFlags
        let v = visibleItems
        if flags.contains(.command) {
            if selection.contains(u) { selection.remove(u) } else { selection.insert(u) }
            current = u
        } else if flags.contains(.shift), let c = current,
                  let a = v.firstIndex(where: { $0.url == c }),
                  let b = v.firstIndex(where: { $0.url == u }) {
            selection = Set(v[min(a, b)...max(a, b)].map(\.url))
        } else {
            select(u)
        }
    }

    func step(_ d: Int) {
        let v = visibleItems
        guard !v.isEmpty else { return }
        let i = v.firstIndex(where: { $0.url == current }) ?? (d > 0 ? -1 : v.count)
        let n = min(max(i + d, 0), v.count - 1)
        select(v[n].url)
    }

    // MARK: 정리 (즐겨찾기 / 삭제 / 이동 / 이름 변경)

    func toggleFavorite(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let paths = urls.map(\.path)
        if paths.allSatisfy({ favorites.contains($0) }) {
            favorites.subtract(paths); toast("즐겨찾기 해제")
        } else {
            favorites.formUnion(paths); toast("즐겨찾기 ★")
        }
    }

    private func removeItems(_ urls: Set<URL>) {
        let oldIndex = visibleItems.firstIndex(where: { $0.url == current }) ?? 0
        let removedCurrent = current.map { urls.contains($0) } ?? false
        items.removeAll { urls.contains($0.url) }
        selection.subtract(urls)
        let v = visibleItems
        if v.isEmpty {
            current = nil; selection = []; viewing = false
        } else if removedCurrent {
            select(v[min(oldIndex, v.count - 1)].url)
        }
    }

    func trash(_ urls: [URL]) {
        var done = Set<URL>()
        var failed = 0
        for u in urls {
            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil); done.insert(u) }
            catch { failed += 1 }
        }
        removeItems(done)
        toast(failed == 0 ? "휴지통으로 이동: \(done.count)개" : "\(done.count)개 이동, \(failed)개 실패")
    }

    func moveToFolder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "여기로 이동"
        guard p.runModal() == .OK, let dest = p.url else { return }
        if dest.standardizedFileURL == folder?.standardizedFileURL { return }
        var done = Set<URL>()
        var failed = 0
        for u in urls {
            let target = Editor.uniqueURL(dir: dest,
                                          base: u.deletingPathExtension().lastPathComponent,
                                          ext: u.pathExtension)
            do {
                try FileManager.default.moveItem(at: u, to: target)
                if favorites.remove(u.path) != nil { favorites.insert(target.path) }
                done.insert(u)
            } catch { failed += 1 }
        }
        removeItems(done)
        toast(failed == 0 ? "\(dest.lastPathComponent) 폴더로 이동: \(done.count)개"
                          : "\(done.count)개 이동, \(failed)개 실패")
    }

    func beginRename(_ u: URL) {
        renameTarget = u
        renameText = u.deletingPathExtension().lastPathComponent
        showRename = true
    }

    func commitRename() {
        guard let old = renameTarget else { return }
        renameTarget = nil
        let base = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !base.contains("/"), !base.contains(":") else {
            toast("사용할 수 없는 이름입니다"); return
        }
        let ext = old.pathExtension
        var new = old.deletingLastPathComponent().appendingPathComponent(base)
        if !ext.isEmpty { new = new.appendingPathExtension(ext) }
        if new == old { return }
        if FileManager.default.fileExists(atPath: new.path) { toast("같은 이름의 파일이 이미 있습니다"); return }
        do {
            try FileManager.default.moveItem(at: old, to: new)
        } catch { toast("이름 변경 실패: \(error.localizedDescription)"); return }
        if favorites.remove(old.path) != nil { favorites.insert(new.path) }
        if let i = items.firstIndex(where: { $0.url == old }) {
            items[i] = ImageFiles.makeItem(new)
        }
        if selection.remove(old) != nil { selection.insert(new) }
        if current == old { current = new }
        sortItems()
        toast("이름 변경: \(new.lastPathComponent)")
    }

    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: 편집

    func crop(_ url: URL, normalized: CGRect) {
        runEdit("자르기", url) { try Editor.crop(source: $0, normalized: normalized) }
    }

    func upscale(_ url: URL, factor: Double) {
        runEdit("\(Int(factor))배 확대", url) { try Editor.upscale(source: $0, factor: factor) }
    }

    func convert(_ url: URL, to format: ImageFormat) {
        runEdit("\(format.label) 변환", url) { try Editor.convert(source: $0, to: format) }
    }

    private func runEdit(_ label: String, _ source: URL, _ work: @escaping @Sendable (URL) throws -> URL) {
        guard !busy else { return }
        busy = true
        toast("\(label) 중…")
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) { try work(source) }.value
                addItem(out)
                toast("\(label) 완료 → \(out.lastPathComponent)")
            } catch {
                toast("\(label) 실패: \(error.localizedDescription)")
            }
            busy = false
        }
    }

    private func addItem(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == folder?.standardizedFileURL else { return }
        items.append(ImageFiles.makeItem(url))
        sortItems()
    }

    // MARK: 알림

    func toast(_ s: String) {
        message = s
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { message = nil }
        }
    }
}
