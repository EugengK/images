import SwiftUI
import AppKit

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "자유", square = "1:1", r43 = "4:3", r34 = "3:4", r32 = "3:2", r169 = "16:9"
    var id: String { rawValue }
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .r43: return 4.0 / 3.0
        case .r34: return 3.0 / 4.0
        case .r32: return 3.0 / 2.0
        case .r169: return 16.0 / 9.0
        }
    }
}

struct ViewerView: View {
    @EnvironmentObject var lib: Library
    @State private var monitor = EventMonitor()
    @State private var viewSize: CGSize = .zero
    @State private var scrollAcc: CGFloat = 0
    @State private var scrollLocked = false

    @State private var image: NSImage?
    @State private var pixelSize: CGSize?
    @State private var zoom: CGFloat = 1          // 1 = 화면에 맞춤
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var showInfo = false
    @State private var cropping = false
    @State private var cropNorm: CGRect?
    @State private var aspect: CropAspect = .free

    // MARK: 계산

    private func fitRect(in size: CGSize) -> CGRect {
        guard let s = pixelSize, s.width > 0, s.height > 0 else { return .zero }
        let sc = min(size.width / s.width, size.height / s.height)
        let w = s.width * sc, h = s.height * sc
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func resetZoom() {
        zoom = 1; baseZoom = 1; offset = .zero; dragStart = .zero
    }

    private func setZoom(_ z: CGFloat) {
        zoom = min(max(z, 0.2), 40); baseZoom = zoom
    }

    /// 100%(픽셀 등배)에 해당하는 zoom 값
    private func actualZoom(_ size: CGSize) -> CGFloat {
        let fit = fitRect(in: size)
        guard let s = pixelSize, fit.width > 0 else { return 1 }
        return s.width / fit.width
    }

    // MARK: 자르기

    private func clamp(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private func normalizedCrop(from a: CGPoint, to b: CGPoint, fit: CGRect) -> CGRect? {
        guard fit.width > 0, fit.height > 0 else { return nil }
        let p0 = clamp(a, fit)
        var p1 = clamp(b, fit)
        if let ratio = aspect.ratio {
            var w = abs(p1.x - p0.x), h = abs(p1.y - p0.y)
            if w / max(h, 0.0001) > ratio { w = h * ratio } else { h = w / ratio }
            p1 = CGPoint(x: p0.x + (p1.x >= p0.x ? w : -w), y: p0.y + (p1.y >= p0.y ? h : -h))
        }
        let r = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
        return CGRect(x: (r.minX - fit.minX) / fit.width, y: (r.minY - fit.minY) / fit.height,
                      width: r.width / fit.width, height: r.height / fit.height)
    }

    private func startCrop() {
        resetZoom(); cropNorm = nil; cropping = true; showInfo = false
    }

    private func applyCrop() {
        guard let u = lib.current, let n = cropNorm, n.width > 0.01, n.height > 0.01 else {
            lib.toast("자를 영역을 드래그로 선택하세요"); return
        }
        lib.crop(u, normalized: n)
        cropping = false; cropNorm = nil
    }

    // MARK: 화면

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let image {
                        Image(nsImage: image)
                            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(zoom).offset(offset)
                    } else {
                        ProgressView().colorScheme(.dark)
                    }
                    if cropping { cropOverlay(geo.size) }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { v in
                        guard !cropping else { return }
                        offset = CGSize(width: dragStart.width + v.translation.width,
                                        height: dragStart.height + v.translation.height)
                    }
                    .onEnded { _ in dragStart = offset })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        guard !cropping else { return }
                        zoom = min(max(baseZoom * v.magnification, 0.2), 40)
                    }
                    .onEnded { _ in baseZoom = zoom })
                .onTapGesture(count: 2) {
                    guard !cropping else { return }
                    if abs(zoom - 1) < 0.01 { setZoom(actualZoom(geo.size)) } else { resetZoom() }
                }
                .overlay(alignment: .top) { topBar }
                .overlay(alignment: .bottom) { if cropping { cropBar } }
                .onAppear { viewSize = geo.size }
                .onChange(of: geo.size) { _, new in viewSize = new }
            }
            if showInfo, let u = lib.current {
                InfoPanel(url: u)
            }
        }
        .onAppear { monitor.start { handle($0) } }
        .onDisappear { monitor.stop() }
        .onChange(of: lib.current) { _, _ in cropping = false; cropNorm = nil }
        .task(id: lib.current) { await loadCurrent() }
    }

    private func loadCurrent() async {
        guard let u = lib.current else { return }
        resetZoom()
        pixelSize = ImageLoader.pixelSize(u)
        image = ImageLoader.cached(u, maxPixel: 2048)
        if image == nil, let t = await ImageLoader.thumbnail(for: u, maxPixel: 2048), lib.current == u {
            image = t
        }
        // 이웃 사진 미리 준비
        let v = lib.visibleItems
        if let i = v.firstIndex(where: { $0.url == u }) {
            for j in [i + 1, i - 1] where v.indices.contains(j) {
                let n = v[j].url
                Task { _ = await ImageLoader.thumbnail(for: n, maxPixel: 2048) }
            }
        }
        if let full = await ImageLoader.full(u), !Task.isCancelled, lib.current == u {
            image = full
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        if e.type == .scrollWheel { return handleScroll(e) }
        if e.modifierFlags.contains(.command) { return false }
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        if cropping {
            if e.keyCode == 53 { cropping = false; cropNorm = nil; return true }
            if e.keyCode == 36 || e.keyCode == 76 { applyCrop(); return true }
            return false
        }
        guard let u = lib.current else { return false }
        switch e.keyCode {
        case 123, 126: lib.step(-1); return true          // ← ↑
        case 124, 125: lib.step(1); return true           // → ↓
        case 53: lib.viewing = false; return true          // Esc
        case 49:                                           // Space
            if abs(zoom - 1) < 0.01 { setZoom(actualZoom(viewSize)) } else { resetZoom() }
            return true
        case 36, 76: NSApp.keyWindow?.toggleFullScreen(nil); return true
        case 51, 117: lib.trash([u]); return true          // Delete
        default: break
        }
        switch ch {
        case "+", "=": setZoom(zoom * 1.25); return true
        case "-": setZoom(zoom / 1.25); return true
        case "0": resetZoom(); return true
        case "i": showInfo.toggle(); return true
        case "c": startCrop(); return true
        case "r": lib.beginRename(u); return true
        case "m": lib.moveToFolder([u]); return true
        case "f": lib.toggleFavorite([u]); return true
        default: return false
        }
    }

    private func handleScroll(_ e: NSEvent) -> Bool {
        guard !cropping else { return false }
        // ⌘ 또는 ⌥ + 휠: 확대/축소
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            let dy = e.scrollingDeltaY
            if dy != 0 { setZoom(zoom * (1 + dy * (e.hasPreciseScrollingDeltas ? 0.01 : 0.05))) }
            return true
        }
        // 확대된 상태: 휠로 화면 이동
        if zoom > 1.01 {
            offset = CGSize(width: offset.width + e.scrollingDeltaX, height: offset.height + e.scrollingDeltaY)
            dragStart = offset
            return true
        }
        // 맞춤 상태: 휠/스와이프로 이전·다음
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        let d = abs(dy) >= abs(dx) ? dy : dx
        if e.hasPreciseScrollingDeltas {                    // 트랙패드
            if e.phase == .began { scrollLocked = false; scrollAcc = 0 }
            if e.phase == .ended || e.phase == .cancelled { scrollLocked = false; scrollAcc = 0 }
            if scrollLocked || e.momentumPhase != [] { return true }
            scrollAcc += d
            if abs(scrollAcc) > 40 {
                lib.step(scrollAcc < 0 ? 1 : -1)
                scrollAcc = 0
                scrollLocked = true                         // 한 번의 스와이프에 한 장만
            }
        } else if d != 0 {                                  // 일반 마우스 휠
            lib.step(d < 0 ? 1 : -1)
        }
        return true
    }

    // MARK: 상단/하단 바

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { lib.viewing = false } label: { Image(systemName: "chevron.left") }
                .help("목록으로 (Esc)")
            if let u = lib.current {
                let v = lib.visibleItems
                let idx = (v.firstIndex(where: { $0.url == u }) ?? 0) + 1
                Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("\(idx) / \(v.count)").foregroundStyle(.secondary).monospacedDigit()
                if let s = pixelSize {
                    Text("\(Int(s.width))×\(Int(s.height))").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            if lib.busy { ProgressView().controlSize(.small) }
            if let u = lib.current {
                Button { lib.toggleFavorite([u]) } label: {
                    Image(systemName: lib.isFavorite(u) ? "star.fill" : "star")
                        .foregroundStyle(lib.isFavorite(u) ? Color.yellow : Color.primary)
                }.help("즐겨찾기 (F)")
                Button { startCrop() } label: { Image(systemName: "crop") }.help("자르기 (C)")
                Menu {
                    Button("2배") { lib.upscale(u, factor: 2) }
                    Button("3배") { lib.upscale(u, factor: 3) }
                    Button("4배") { lib.upscale(u, factor: 4) }
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .menuStyle(.borderlessButton).fixedSize().help("업스케일 (사본 저장)")
                Menu {
                    ForEach(ImageFormat.allCases) { f in
                        Button("\(f.label)로 변환") { lib.convert(u, to: f) }
                    }
                } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .menuStyle(.borderlessButton).fixedSize().help("형식 변환 (사본 저장)")
                Button { lib.beginRename(u) } label: { Image(systemName: "pencil") }.help("이름 바꾸기 (R)")
                Button { lib.moveToFolder([u]) } label: { Image(systemName: "folder") }.help("이동 (M)")
                Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }.help("정보 (I)")
                Button { lib.trash([u]) } label: { Image(systemName: "trash") }.help("휴지통으로 (Delete)")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .opacity(cropping ? 0.5 : 1)
    }

    private var cropBar: some View {
        HStack(spacing: 12) {
            Text("드래그로 영역 선택").foregroundStyle(.secondary)
            Picker("비율", selection: $aspect) {
                ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 260)
            Button("취소 (Esc)") { cropping = false; cropNorm = nil }
            Button("사본으로 저장 (Return)") { applyCrop() }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func cropOverlay(_ size: CGSize) -> some View {
        let fit = fitRect(in: size)
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        cropNorm = normalizedCrop(from: v.startLocation, to: v.location, fit: fit)
                    })
            if let n = cropNorm {
                let r = CGRect(x: fit.minX + n.minX * fit.width, y: fit.minY + n.minY * fit.height,
                               width: n.width * fit.width, height: n.height * fit.height)
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }
        }
    }
}
