import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct InfoRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

struct InfoPanel: View {
    let url: URL
    @State private var rows: [InfoRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.label).font(.caption).foregroundStyle(.secondary)
                        Text(r.value).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(width: 270)
        .background(.regularMaterial)
        .task(id: url) {
            let u = url
            rows = await Task.detached { InfoReader.read(u) }.value
        }
    }
}

enum InfoReader {
    static func read(_ url: URL) -> [InfoRow] {
        var r: [InfoRow] = [
            InfoRow("파일", url.lastPathComponent),
            InfoRow("위치", url.deletingLastPathComponent().path)
        ]
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .medium
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let s = a[.size] as? Int {
                r.append(InfoRow("용량", ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)))
            }
            if let d = a[.creationDate] as? Date { r.append(InfoRow("생성", df.string(from: d))) }
            if let d = a[.modificationDate] as? Date { r.append(InfoRow("수정", df.string(from: d))) }
        }
        if let t = UTType(filenameExtension: url.pathExtension)?.localizedDescription {
            r.append(InfoRow("형식", t))
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return r }

        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            let mp = Double(w * h) / 1_000_000
            r.append(InfoRow("해상도", "\(w) × \(h)  (\(String(format: "%.1f", mp))MP)"))
        }
        if let dpi = p[kCGImagePropertyDPIWidth] as? Double { r.append(InfoRow("DPI", String(Int(dpi)))) }
        if let cs = p[kCGImagePropertyColorModel] as? String { r.append(InfoRow("색상 모델", cs)) }

        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let cam = [make, model].compactMap { $0 }.joined(separator: " ")
        if !cam.isEmpty { r.append(InfoRow("카메라", cam)) }

        if let e = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let v = e[kCGImagePropertyExifDateTimeOriginal] as? String { r.append(InfoRow("촬영일", v)) }
            if let v = e[kCGImagePropertyExifLensModel] as? String { r.append(InfoRow("렌즈", v)) }
            if let f = e[kCGImagePropertyExifFocalLength] as? Double {
                r.append(InfoRow("초점거리", "\(String(format: "%g", f)) mm"))
            }
            if let f = e[kCGImagePropertyExifFNumber] as? Double {
                r.append(InfoRow("조리개", "f/\(String(format: "%g", f))"))
            }
            if let t = e[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                r.append(InfoRow("셔터속도", t >= 1 ? "\(String(format: "%g", t)) s" : "1/\(Int((1 / t).rounded())) s"))
            }
            if let iso = (e[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
                r.append(InfoRow("ISO", String(iso)))
            }
        }
        if let g = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = g[kCGImagePropertyGPSLatitude] as? Double,
           var lon = g[kCGImagePropertyGPSLongitude] as? Double {
            if (g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            r.append(InfoRow("위치(GPS)", String(format: "%.5f, %.5f", lat, lon)))
        }
        return r
    }
}
