import AppKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

enum ImageFiles {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "avif",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2"
    ]

    static func makeItem(_ u: URL) -> ImageItem {
        let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ImageItem(url: u, modified: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0)
    }

    /// 폴더 안의 이미지와 하위 폴더를 읽는다 (비재귀).
    static func scan(_ folder: URL) -> (items: [ImageItem], subfolders: [URL]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var items: [ImageItem] = []
        var dirs: [URL] = []
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if u.pathExtension.lowercased() != "app" { dirs.append(u) }
                continue
            }
            guard extensions.contains(u.pathExtension.lowercased()) else { continue }
            items.append(ImageItem(url: u,
                                   modified: v?.contentModificationDate ?? .distantPast,
                                   size: v?.fileSize ?? 0))
        }
        dirs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (items, dirs)
    }
}

/// 동시에 디코딩하는 개수를 제한한다 (빠른 스크롤 시 CPU/메모리 폭주 방지).
actor DecodeGate {
    private var running = 0
    private let limit: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func acquire() async {
        if running < limit { running += 1 }
        else { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

enum ImageLoader {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 400_000_000
        return c
    }()
    private static let gate = DecodeGate(limit: 4)

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.path)|\(maxPixel)" as NSString
    }

    static func cached(_ url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    /// 방향(EXIF orientation)이 적용된 축소 이미지. maxPixel이 원본보다 크면 원본 크기.
    static func decode(_ url: URL, maxPixel: Int?) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var limit = maxPixel ?? Int.max
        if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = p[kCGImagePropertyPixelWidth] as? Int,
           let h = p[kCGImagePropertyPixelHeight] as? Int {
            limit = min(limit, max(w, h))
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func thumbnail(for url: URL, maxPixel: Int) async -> NSImage? {
        if let c = cached(url, maxPixel: maxPixel) { return c }
        await gate.acquire()
        if Task.isCancelled { await gate.release(); return nil }   // 화면 밖으로 사라진 셀은 건너뜀
        let cg = await Task.detached(priority: .utility) { decode(url, maxPixel: maxPixel) }.value
        await gate.release()
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key(url, maxPixel), cost: cg.width * cg.height * 4)
        return img
    }

    static func full(_ url: URL) async -> NSImage? {
        let cg = await Task.detached(priority: .userInitiated) { decode(url, maxPixel: nil) }.value
        guard let cg else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 방향이 적용된 픽셀 크기 (헤더만 읽음)
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int,
              let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(o) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}

// MARK: - 편집 (자르기 / 업스케일 / 형식 변환)

enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic
    var id: String { rawValue }
    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        }
    }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var label: String { rawValue.uppercased() }

    static func from(ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic", "heif": return .heic
        default: return nil
        }
    }
}

enum EditError: LocalizedError {
    case load, render, write, tooLarge, sameFormat
    var errorDescription: String? {
        switch self {
        case .load: return "이미지를 읽을 수 없습니다"
        case .render: return "이미지 처리에 실패했습니다"
        case .write: return "파일을 저장할 수 없습니다"
        case .tooLarge: return "결과 이미지가 너무 큽니다 (2억 화소 초과)"
        case .sameFormat: return "이미 같은 형식입니다"
        }
    }
}

enum Editor {
    static func uniqueURL(dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var u = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return u
    }

    private static func write(_ cg: CGImage, to url: URL, format: ImageFormat, source: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw EditError.write }
        var props: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(source as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            // 촬영 정보는 유지하되, 픽셀은 이미 회전되어 있으므로 방향은 1로 고정
            if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = nil
                exif[kCGImagePropertyExifPixelYDimension] = nil
                props[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            if let gps = p[kCGImagePropertyGPSDictionary] { props[kCGImagePropertyGPSDictionary] = gps }
        }
        props[kCGImagePropertyOrientation] = 1
        if format != .png { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EditError.write }
    }

    private static func outputFormat(for source: URL) -> ImageFormat {
        ImageFormat.from(ext: source.pathExtension) ?? .png
    }

    /// normalized: 0...1 좌표(좌상단 기준)의 자를 영역. 원본은 그대로 두고 사본을 만든다.
    static func crop(source: URL, normalized n: CGRect) throws -> URL {
        guard let cg = ImageLoader.decode(source, maxPixel: nil) else { throw EditError.load }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: (n.minX * w).rounded(), y: (n.minY * h).rounded(),
                          width: (n.width * w).rounded(), height: (n.height * h).rounded())
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width >= 1, rect.height >= 1, let out = cg.cropping(to: rect) else { throw EditError.render }
        let fmt = outputFormat(for: source)
        let base = source.deletingPathExtension().lastPathComponent + "_crop"
        let url = uniqueURL(dir: source.deletingLastPathComponent(), base: base, ext: fmt.ext)
        try write(out, to: url, format: fmt, source: source)
        return url
    }

    /// Lanczos 확대 + 약한 샤프닝. (AI 초해상도가 아니라 고품질 보간 확대입니다.)
    static func upscale(source: URL, factor: Double) throws -> URL {
        guard let cg = ImageLoader.decode(source, maxPixel: nil) else { throw EditError.load }
        let outPixels = Double(cg.width) * Double(cg.height) * factor * factor
        guard outPixels <= 200_000_000 else { throw EditError.tooLarge }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = CIImage(cgImage: cg)
        f.scale = Float(factor)
        f.aspectRatio = 1
        guard var out = f.outputImage else { throw EditError.render }
        let sh = CIFilter.sharpenLuminance()
        sh.inputImage = out
        sh.sharpness = 0.3
        if let o = sh.outputImage { out = o }
        let ctx = CIContext()
        guard let res = ctx.createCGImage(out, from: out.extent) else { throw EditError.render }
        let fmt = outputFormat(for: source)
        let label = factor == factor.rounded() ? "\(Int(factor))x" : "\(factor)x"
        let url = uniqueURL(dir: source.deletingLastPathComponent(),
                            base: source.deletingPathExtension().lastPathComponent + "_" + label,
                            ext: fmt.ext)
        try write(res, to: url, format: fmt, source: source)
        return url
    }

    static func convert(source: URL, to format: ImageFormat) throws -> URL {
        if ImageFormat.from(ext: source.pathExtension) == format { throw EditError.sameFormat }
        guard let cg = ImageLoader.decode(source, maxPixel: nil) else { throw EditError.load }
        let url = uniqueURL(dir: source.deletingLastPathComponent(),
                            base: source.deletingPathExtension().lastPathComponent, ext: format.ext)
        try write(cg, to: url, format: format, source: source)
        return url
    }
}
