import AppKit
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PDF → SVG. One page gives `<stem>.svg`, several give `<stem> Pages/Page N.svg`. Each page goes through a
/// native content-stream interpreter; what SVG can't express becomes a PNG patch of the rendered page.
/// A page that can't be expressed at all, or that doesn't match its own rendering, is embedded as one image.
enum PDFToSVG {
    static func export(_ document: PDFDocument, beside source: URL, progress: @escaping (Double) -> Void) throws -> URL {
        guard document.pageCount > 1 else {
            let output = OutputNaming.destination(for: source, extension: "svg")
            try writePage(0, of: document, to: output)
            progress(1)
            return output
        }
        // The pages only appear beside the source once all of them exist.
        let saveFailure = ConversionError.encodingFailed("Could not save the PDF page image.")
        let parent = source.deletingLastPathComponent()
        let working = parent.appendingPathComponent(".satsuma-pdf-pages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: working) }
        do { try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true) } catch { throw saveFailure }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try writePage(index, of: document, to: working.appendingPathComponent("Page \(index + 1).svg"))
            progress(Double(index + 1) / Double(document.pageCount))
        }
        let stem = source.deletingPathExtension().lastPathComponent
        var folder = parent.appendingPathComponent("\(stem) Pages")
        var number = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(stem) Pages \(number)")
            number += 1
        }
        do { try FileManager.default.moveItem(at: working, to: folder) } catch { throw saveFailure }
        return folder
    }

    /// One pool per page, because a page's fonts, images and renderings would otherwise pile up until the document is done.
    private static func writePage(_ index: Int, of document: PDFDocument, to output: URL) throws {
        guard let page = document.page(at: index) else {
            throw ConversionError.encodingFailed("A PDF page has invalid dimensions or could not be rendered.")
        }
        try autoreleasepool {
            do {
                try Data(try svg(for: page).utf8).write(to: output, options: .atomic)
            } catch let error as ConversionError {
                throw error
            } catch {
                throw ConversionError.encodingFailed("Could not save the PDF page image.")
            }
        }
    }

    static func svg(for page: PDFPage) throws -> String {
        guard let geometry = PageGeometry(page), !FormFanOut.exceedsLimit(page) else {
            throw ConversionError.encodingFailed("A PDF page has invalid dimensions or could not be rendered.")
        }
        if let vector = PDFSVGInterpreter(page: page, geometry: geometry)?.render(), matches(vector, page: page, geometry: geometry) {
            return vector
        }
        return try rasterSVG(page, geometry: geometry)
    }

    /// The header the interpreter and the raster fallback share.
    fileprivate static func header(_ geometry: PageGeometry) -> String {
        let w = svgNumber(geometry.width), h = svgNumber(geometry.height)
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">"
    }

    /// Bitmap scale for the whole page and its patches: at most 300 dpi, 16 megapixels and 8192 px per side.
    fileprivate static func rasterScale(_ geometry: PageGeometry) -> CGFloat {
        min(8192 / max(geometry.width, geometry.height), sqrt(16_000_000 / (geometry.width * geometry.height)), 300.0 / 72.0)
    }

    private static func rasterSVG(_ page: PDFPage, geometry: PageGeometry) throws -> String {
        guard let image = pageBitmap(page, geometry: geometry, scale: rasterScale(geometry), white: true) else {
            throw ConversionError.encodingFailed("Could not create the PDF page image.")
        }
        guard let png = pngData(image) else { throw ConversionError.encodingFailed("Could not save the PDF page image.") }
        let w = svgNumber(geometry.width), h = svgNumber(geometry.height)
        return header(geometry) + "<image width=\"\(w)\" height=\"\(h)\" preserveAspectRatio=\"none\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/></svg>"
    }

    fileprivate static func pageBitmap(_ page: PDFPage, geometry: PageGeometry, scale: CGFloat, white: Bool) -> CGImage? {
        let width = Int((geometry.width * scale).rounded()), height = Int((geometry.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if white {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.scaleBy(x: CGFloat(width) / geometry.width, y: CGFloat(height) / geometry.height)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    /// Renders the finished SVG and the PDF page to the same small gray bitmaps. A vector page that is far from
    /// its own rendering (a font the outlines got wrong, a mark drawn in the wrong place) is not trustworthy.
    private static func matches(_ svg: String, page: PDFPage, geometry: PageGeometry) -> Bool {
        guard svg.utf8.count < 40_000_000, let image = NSImage(data: Data(svg.utf8)) else { return true }
        let scale = min(1, 1200 / max(geometry.width, geometry.height))
        let width = max(1, Int(geometry.width * scale)), height = max(1, Int(geometry.height * scale))
        func gray(_ draw: (CGContext) -> Void) -> [UInt8]? {
            // NSImage's SVG drawing needs an RGB destination; a DeviceGray bitmap stays blank.
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = context.data else { return nil }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(context)
            let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            return (0..<(width * height)).map { index in
                let p = bytes + index * 4
                return UInt8((UInt32(p[0]) * 54 + UInt32(p[1]) * 183 + UInt32(p[2]) * 19) >> 8)
            }
        }
        let box = NSRect(x: 0, y: 0, width: width, height: height)
        guard let drawn = gray({ context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
        }), let expected = gray({ context in
            context.scaleBy(x: CGFloat(width) / geometry.width, y: CGFloat(height) / geometry.height)
            page.draw(with: .cropBox, to: context)
        }) else { return true }
        // Blurring both by a few pixels makes small anti-aliasing differences irrelevant, and the 10% limit
        // leaves room for what NSImage's own SVG renderer doesn't support (e.g. even-odd clips).
        let a = boxBlur(drawn, width: width, height: height), b = boxBlur(expected, width: width, height: height)
        var mismatched = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > 40 { mismatched += 1 }
        return Double(mismatched) <= Double(width * height) * 0.10
    }

    private static func boxBlur(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let radius = 2
        var sums = [Int](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            for x in 0..<width {
                sums[(y + 1) * (width + 1) + x + 1] = Int(pixels[y * width + x]) + sums[y * (width + 1) + x + 1] + sums[(y + 1) * (width + 1) + x] - sums[y * (width + 1) + x]
            }
        }
        var out = pixels
        for y in 0..<height {
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width, x + radius + 1), y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
                let total = sums[y1 * (width + 1) + x1] - sums[y0 * (width + 1) + x1] - sums[y1 * (width + 1) + x0] + sums[y0 * (width + 1) + x0]
                out[y * width + x] = UInt8(total / ((x1 - x0) * (y1 - y0)))
            }
        }
        return out
    }
}

// MARK: - Geometry and numbers

/// Page size in points after rotation, and the map from default user space to SVG space (Y down).
struct PageGeometry {
    let width: CGFloat
    let height: CGFloat
    let base: CGAffineTransform

    init?(_ page: PDFPage) {
        guard let cgPage = page.pageRef else { return nil }
        self.init(box: cgPage.getBoxRect(.cropBox), rotation: Int(cgPage.rotationAngle))
    }

    init?(box: CGRect, rotation: Int) {
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            width = box.height; height = box.width
            base = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: -box.minY, ty: -box.minX)
        case 180:
            width = box.width; height = box.height
            base = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: box.maxX, ty: -box.minY)
        case 270:
            width = box.height; height = box.width
            base = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: box.maxY, ty: box.maxX)
        default:
            width = box.width; height = box.height
            base = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY)
        }
    }
}

/// Shortest fixed notation with the given decimals; never NaN, Infinity, or "-0".
func svgNumber(_ value: CGFloat, places: Int = 3) -> String {
    guard value.isFinite, abs(value) < 1e12 else { return "0" }
    var factor: Int64 = 1
    for _ in 0..<places { factor *= 10 }
    let scaled = Int64((value * CGFloat(factor)).rounded())
    if scaled == 0 { return "0" }
    let negative = scaled < 0
    let magnitude = negative ? -scaled : scaled
    let whole = magnitude / factor
    var text = negative ? "-\(whole)" : "\(whole)"
    var fraction = magnitude % factor
    if fraction == 0 { return text }
    var digits = places
    while fraction % 10 == 0 { fraction /= 10; digits -= 1 }
    let tail = String(fraction)
    text += "." + String(repeating: "0", count: digits - tail.count) + tail
    return text
}

fileprivate func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

// MARK: - Form fan-out

/// Counts the Form XObject draws a page asks for, multiplying through nesting. A few kilobytes can ask for billions,
/// which Quartz would spend hours on with no way to interrupt it, so such a page is refused before anything draws it.
final class FormFanOut {
    private static let limit = 5_000_000.0

    private var costs: [UnsafeRawPointer: Double] = [:]
    private var active = Set<UnsafeRawPointer>()
    private var content: CGPDFContentStreamRef?
    private var draws = 0.0

    private static let table: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            var name: UnsafePointer<CChar>?
            guard let info, CGPDFScannerPopName(scanner, &name), let name else { return }
            Unmanaged<FormFanOut>.fromOpaque(info).takeUnretainedValue().visit(String(cString: name))
        }
        return table
    }()

    static func exceedsLimit(_ page: PDFPage) -> Bool {
        guard let cgPage = page.pageRef else { return false }
        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        defer { CGPDFContentStreamRelease(stream) }
        return FormFanOut().scan(stream) > limit
    }

    private func scan(_ stream: CGPDFContentStreamRef) -> Double {
        let outerContent = content, outerDraws = draws
        defer { content = outerContent; draws = outerDraws }
        content = stream
        draws = 0
        let scanner = CGPDFScannerCreate(stream, Self.table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        return draws
    }

    private func visit(_ name: String) {
        guard let content, let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream),
              pdfName(dictionary, "Subtype") == "Form" else { return }
        draws += 1 + cost(stream, dictionary: dictionary, parent: content)
    }

    /// Each form is read once; a form already open is a cycle, which the renderers stop on their own.
    private func cost(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, parent: CGPDFContentStreamRef) -> Double {
        let key = objectKey(stream)
        if let known = costs[key] { return known }
        guard active.count < 64, active.insert(key).inserted else { return 0 }
        defer { active.remove(key) }
        let form = CGPDFContentStreamCreateWithStream(stream, pdfDictionary(dictionary, "Resources") ?? dictionary, parent)
        defer { CGPDFContentStreamRelease(form) }
        let total = scan(form)
        costs[key] = total
        return total
    }
}

// MARK: - PDF object helpers

/// A number read from a file as an Int; a malformed PDF can hold values no Int can represent.
fileprivate func pdfInt(_ value: CGFloat) -> Int { value.isFinite ? Int(max(min(value, 1e15), -1e15)) : 0 }

/// A stable key for a PDF object (dictionaries and streams are kept alive by their document).
fileprivate func objectKey<T>(_ object: T) -> UnsafeRawPointer { unsafeBitCast(object, to: UnsafeRawPointer.self) }

fileprivate func pdfName(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
    var value: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
    return String(cString: value)
}

fileprivate func pdfDictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
    var value: CGPDFDictionaryRef?
    return CGPDFDictionaryGetDictionary(dictionary, key, &value) ? value : nil
}

fileprivate func pdfArray(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
    var value: CGPDFArrayRef?
    return CGPDFDictionaryGetArray(dictionary, key, &value) ? value : nil
}

fileprivate func pdfStream(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
    var value: CGPDFStreamRef?
    return CGPDFDictionaryGetStream(dictionary, key, &value) ? value : nil
}

fileprivate func pdfNumber(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGFloat? {
    var value: CGPDFReal = 0
    return CGPDFDictionaryGetNumber(dictionary, key, &value) ? value : nil
}

fileprivate func pdfBool(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool? {
    var value: CGPDFBoolean = 0
    return CGPDFDictionaryGetBoolean(dictionary, key, &value) ? value != 0 : nil
}

fileprivate func pdfNumbers(_ array: CGPDFArrayRef) -> [CGFloat] {
    (0..<CGPDFArrayGetCount(array)).map { index in
        var value: CGPDFReal = 0
        return CGPDFArrayGetNumber(array, index, &value) ? value : 0
    }
}

fileprivate func pdfNumbers(_ dictionary: CGPDFDictionaryRef, _ key: String) -> [CGFloat]? {
    pdfArray(dictionary, key).map(pdfNumbers)
}

fileprivate func pdfMatrix(_ numbers: [CGFloat]?) -> CGAffineTransform? {
    guard let n = numbers, n.count >= 6 else { return nil }
    return CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
}

fileprivate func pdfData(_ stream: CGPDFStreamRef) -> (data: Data, format: CGPDFDataFormat)? {
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
    return (data as Data, format)
}

fileprivate func pdfBytes(_ string: CGPDFStringRef) -> [UInt8] {
    guard let pointer = CGPDFStringGetBytePtr(string) else { return [] }
    return Array(UnsafeBufferPointer(start: pointer, count: CGPDFStringGetLength(string)))
}

// MARK: - Functions (tint transforms)

/// PDF functions, types 0, 2, 3 and 4. Used for Separation and DeviceN tint transforms.
fileprivate final class PDFTintFunction {
    private enum Body {
        case sampled(size: [Int], encode: [CGFloat], decode: [CGFloat], samples: [CGFloat], outputs: Int)
        case exponential(c0: [CGFloat], c1: [CGFloat], n: CGFloat)
        case stitching(functions: [PDFTintFunction], bounds: [CGFloat], encode: [CGFloat])
        case postscript([PSToken])
    }

    private indirect enum PSToken { case number(Double), op(String), block([PSToken]) }

    private let body: Body
    private let domain: [CGFloat]
    private let range: [CGFloat]

    init?(_ object: CGPDFObjectRef, depth: Int = 0) {
        guard depth < 8 else { return nil }
        var dictionary: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        if CGPDFObjectGetValue(object, .stream, &stream), let stream { dictionary = CGPDFStreamGetDictionary(stream) } else { _ = CGPDFObjectGetValue(object, .dictionary, &dictionary) }
        guard let dictionary else { return nil }
        var type: CGPDFInteger = -1
        guard CGPDFDictionaryGetInteger(dictionary, "FunctionType", &type), let domain = pdfNumbers(dictionary, "Domain") else { return nil }
        self.domain = domain
        range = pdfNumbers(dictionary, "Range") ?? []
        switch type {
        case 0:
            guard let stream, let sizes = pdfNumbers(dictionary, "Size"), let bps = pdfNumber(dictionary, "BitsPerSample"),
                  !range.isEmpty, [1, 2, 4, 8, 12, 16, 24, 32].contains(pdfInt(bps)), let raw = pdfData(stream)?.data else { return nil }
            let size = sizes.map(pdfInt)
            let inputs = domain.count / 2, outputs = range.count / 2
            guard size.count == inputs, inputs <= 4, size.allSatisfy({ $0 > 0 && $0 <= 4_000_000 }) else { return nil }
            let total = size.reduce(outputs) { min($0 * $1, 4_000_001) }
            guard total <= 4_000_000, raw.count * 8 >= total * Int(bps) else { return nil }
            let top = pow(2, Double(bps)) - 1
            var samples = [CGFloat](repeating: 0, count: total)
            var bit = 0
            for index in 0..<total {
                var value: UInt64 = 0
                for _ in 0..<Int(bps) {
                    value = (value << 1) | UInt64((raw[raw.startIndex + bit / 8] >> UInt8(7 - bit % 8)) & 1)
                    bit += 1
                }
                samples[index] = CGFloat(Double(value) / top)
            }
            let encode = pdfNumbers(dictionary, "Encode") ?? size.flatMap { [0, CGFloat($0 - 1)] }
            body = .sampled(size: size, encode: encode, decode: pdfNumbers(dictionary, "Decode") ?? range, samples: samples, outputs: outputs)
        case 2:
            body = .exponential(c0: pdfNumbers(dictionary, "C0") ?? [0], c1: pdfNumbers(dictionary, "C1") ?? [1], n: pdfNumber(dictionary, "N") ?? 1)
        case 3:
            guard let list = pdfArray(dictionary, "Functions"), let bounds = pdfNumbers(dictionary, "Bounds"), let encode = pdfNumbers(dictionary, "Encode") else { return nil }
            var functions: [PDFTintFunction] = []
            for index in 0..<CGPDFArrayGetCount(list) {
                var item: CGPDFObjectRef?
                guard CGPDFArrayGetObject(list, index, &item), let item, let function = PDFTintFunction(item, depth: depth + 1) else { return nil }
                functions.append(function)
            }
            guard !functions.isEmpty, bounds.count == functions.count - 1, encode.count >= functions.count * 2 else { return nil }
            body = .stitching(functions: functions, bounds: bounds, encode: encode)
        case 4:
            guard let stream, let raw = pdfData(stream)?.data else { return nil }
            var tokens = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "{", with: " { ").replacingOccurrences(of: "}", with: " } ")
                .split(whereSeparator: \.isWhitespace).map(String.init)[...]
            guard tokens.popFirst() == "{" else { return nil }
            body = .postscript(Self.parseBlock(&tokens))
        default:
            return nil
        }
    }

    private static func parseBlock(_ tokens: inout ArraySlice<String>) -> [PSToken] {
        var out: [PSToken] = []
        while let token = tokens.popFirst() {
            if token == "}" { return out }
            if token == "{" { out.append(.block(parseBlock(&tokens))) } else if let number = Double(token) { out.append(.number(number)) } else { out.append(.op(token)) }
        }
        return out
    }

    func evaluate(_ input: [CGFloat]) -> [CGFloat] {
        let clamped = input.enumerated().map { index, value -> CGFloat in
            guard index * 2 + 1 < domain.count else { return value }
            return min(max(value, domain[index * 2]), domain[index * 2 + 1])
        }
        var output: [CGFloat]
        switch body {
        case let .sampled(size, encode, decode, samples, outputs):
            output = Self.sample(clamped, domain: domain, size: size, encode: encode, decode: decode, samples: samples, outputs: outputs)
        case let .exponential(c0, c1, n):
            let x = clamped.first ?? 0, power = n == 1 ? x : pow(x, n)
            output = c0.indices.map { $0 < c1.count ? c0[$0] + power * (c1[$0] - c0[$0]) : c0[$0] }
        case let .stitching(functions, bounds, encode):
            let x = clamped.first ?? 0
            let index = bounds.firstIndex(where: { x < $0 }) ?? functions.count - 1
            let low = index == 0 ? domain[0] : bounds[index - 1], high = index == functions.count - 1 ? domain[1] : bounds[index]
            let e0 = encode[index * 2], e1 = encode[index * 2 + 1]
            output = functions[index].evaluate([high > low ? e0 + (x - low) / (high - low) * (e1 - e0) : e0])
        case let .postscript(program):
            var stack = clamped.map { Double($0) }
            var budget = 100_000
            Self.run(program, stack: &stack, budget: &budget)
            output = stack.map { CGFloat($0) }
            if !range.isEmpty, output.count > range.count / 2 { output = Array(output.suffix(range.count / 2)) }
        }
        if !range.isEmpty {
            output = output.enumerated().map { index, value in
                index * 2 + 1 < range.count ? min(max(value, range[index * 2]), range[index * 2 + 1]) : value
            }
        }
        return output
    }

    private static func sample(_ input: [CGFloat], domain: [CGFloat], size: [Int], encode: [CGFloat], decode: [CGFloat], samples: [CGFloat], outputs: Int) -> [CGFloat] {
        let coordinates: [CGFloat] = size.indices.map { i in
            let x0 = domain[i * 2], x1 = domain[i * 2 + 1], value = i < input.count ? input[i] : x0
            let encoded = x1 > x0 ? encode[i * 2] + (value - x0) / (x1 - x0) * (encode[i * 2 + 1] - encode[i * 2]) : encode[i * 2]
            return min(max(encoded, 0), CGFloat(size[i] - 1))
        }
        var result = [CGFloat](repeating: 0, count: outputs)
        for corner in 0..<(1 << size.count) {
            var weight: CGFloat = 1
            var offset = 0, stride = 1
            for i in size.indices {
                let low = pdfInt(coordinates[i].rounded(.down)), fraction = coordinates[i] - CGFloat(low)
                let useHigh = corner & (1 << i) != 0
                weight *= useHigh ? fraction : 1 - fraction
                offset += min(low + (useHigh ? 1 : 0), size[i] - 1) * stride
                stride *= size[i]
            }
            guard weight > 0 else { continue }
            for j in 0..<outputs { result[j] += weight * samples[offset * outputs + j] }
        }
        return result.indices.map { j in
            let d0 = j * 2 + 1 < decode.count ? decode[j * 2] : 0, d1 = j * 2 + 1 < decode.count ? decode[j * 2 + 1] : 1
            return d0 + result[j] * (d1 - d0)
        }
    }

    private static func run(_ program: [PSToken], stack: inout [Double], budget: inout Int) {
        var index = 0
        func pop() -> Double { stack.popLast() ?? 0 }
        func binary(_ body: (Double, Double) -> Double) { let b = pop(), a = pop(); stack.append(body(a, b)) }
        func unary(_ body: (Double) -> Double) { stack.append(body(pop())) }
        func flag(_ value: Bool) -> Double { value ? 1 : 0 }
        func int(_ value: Double) -> Int { value.isFinite ? Int(max(min(value, 1e15), -1e15)) : 0 }
        while index < program.count {
            budget -= 1
            guard budget > 0 else { return }
            defer { index += 1 }
            switch program[index] {
            case .number(let value): stack.append(value)
            case .block: break
            case .op(let name):
                switch name {
                case "add": binary(+)
                case "sub": binary(-)
                case "mul": binary(*)
                case "div": binary { $1 == 0 ? 0 : $0 / $1 }
                case "idiv": binary { $1 == 0 ? 0 : Double(int($0) / int($1)) }
                case "mod": binary { int($1) == 0 ? 0 : Double(int($0) % int($1)) }
                case "neg": unary(-)
                case "abs": unary(abs)
                case "ceiling": unary { $0.rounded(.up) }
                case "floor": unary { $0.rounded(.down) }
                case "round": unary { ($0 + 0.5).rounded(.down) }
                case "truncate", "cvi": unary { $0.rounded(.towardZero) }
                case "cvr": break
                case "sqrt": unary { $0 < 0 ? 0 : $0.squareRoot() }
                case "sin": unary { sin($0 * .pi / 180) }
                case "cos": unary { cos($0 * .pi / 180) }
                case "atan": binary { let v = atan2($0, $1) * 180 / .pi; return v < 0 ? v + 360 : v }
                case "exp": binary { pow($0, $1) }
                case "ln": unary { $0 > 0 ? log($0) : 0 }
                case "log": unary { $0 > 0 ? log10($0) : 0 }
                case "eq": binary { flag($0 == $1) }
                case "ne": binary { flag($0 != $1) }
                case "gt": binary { flag($0 > $1) }
                case "ge": binary { flag($0 >= $1) }
                case "lt": binary { flag($0 < $1) }
                case "le": binary { flag($0 <= $1) }
                case "and": binary { Double(int($0) & int($1)) }
                case "or": binary { Double(int($0) | int($1)) }
                case "xor": binary { Double(int($0) ^ int($1)) }
                case "not": unary { $0 == 0 ? 1 : 0 }
                case "bitshift": binary { $1 >= 0 ? Double(int($0) << min(int($1), 62)) : Double(int($0) >> min(-int($1), 62)) }
                case "true": stack.append(1)
                case "false": stack.append(0)
                case "pop": _ = pop()
                case "exch": let b = pop(), a = pop(); stack.append(b); stack.append(a)
                case "dup": let a = pop(); stack.append(a); stack.append(a)
                case "copy":
                    let n = int(pop())
                    if n > 0, n <= stack.count { stack.append(contentsOf: stack.suffix(n)) }
                case "index":
                    let n = int(pop())
                    stack.append(n >= 0 && n < stack.count ? stack[stack.count - 1 - n] : 0)
                case "roll":
                    let j = int(pop()), n = int(pop())
                    if n > 0, n <= stack.count {
                        let shift = ((j % n) + n) % n
                        let tail = Array(stack.suffix(n))
                        stack.removeLast(n)
                        stack.append(contentsOf: tail.suffix(shift) + tail.prefix(n - shift))
                    }
                case "if":
                    if index >= 1, case .block(let then) = program[index - 1], pop() != 0 { run(then, stack: &stack, budget: &budget) }
                case "ifelse":
                    if index >= 2, case .block(let then) = program[index - 2], case .block(let other) = program[index - 1] {
                        run(pop() != 0 ? then : other, stack: &stack, budget: &budget)
                    }
                default: break
                }
            }
        }
    }
}

// MARK: - Colour

fileprivate struct SVGColor: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    static let black = SVGColor(r: 0, g: 0, b: 0)

    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v.isFinite ? v : 0, 0), 1) * 255).rounded()) }
        self.init(r: byte(red), g: byte(green), b: byte(blue))
    }

    var hex: String {
        if r == 0, g == 0, b == 0 { return "#000" }
        let digits = Array("0123456789abcdef")
        return String(["#", digits[Int(r >> 4)], digits[Int(r & 15)], digits[Int(g >> 4)], digits[Int(g & 15)], digits[Int(b >> 4)], digits[Int(b & 15)]])
    }
}

fileprivate enum Paint: Equatable { case color(SVGColor), pattern, none }

fileprivate indirect enum ColorModel {
    case gray, rgb, cmyk
    case icc(CGColorSpace, Int)
    case lab(CGColorSpace)
    case indexed(ColorModel, Int, [UInt8])
    case tint(Int, ColorModel, PDFTintFunction?, isNone: Bool)
    case pattern(ColorModel?)

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let genericCMYK = CGColorSpace(name: CGColorSpace.genericCMYK) ?? CGColorSpaceCreateDeviceCMYK()

    var componentCount: Int {
        switch self {
        case .gray, .indexed, .tint(1, _, _, _): return 1
        case .tint(let n, _, _, _): return n
        case .rgb, .lab: return 3
        case .cmyk: return 4
        case .icc(_, let n): return n
        case .pattern: return 0
        }
    }

    var initialComponents: [CGFloat] {
        switch self {
        case .cmyk: return [0, 0, 0, 1]
        case .icc(_, 4): return [0, 0, 0, 1]
        case .tint(let n, _, _, _): return Array(repeating: 1, count: n)
        default: return Array(repeating: 0, count: componentCount)
        }
    }

    /// Paint for a component vector. A colour that can't be computed degrades to black, which stays visible.
    func paint(_ components: [CGFloat]) -> Paint {
        switch self {
        case .pattern: return .pattern
        case .tint(_, _, _, true): return .none
        default: return .color(color(components))
        }
    }

    func color(_ components: [CGFloat]) -> SVGColor {
        func component(_ index: Int) -> CGFloat { index < components.count ? components[index] : 0 }
        switch self {
        case .gray: return SVGColor(red: component(0), green: component(0), blue: component(0))
        case .rgb: return SVGColor(red: component(0), green: component(1), blue: component(2))
        case .cmyk: return Self.converted(Self.genericCMYK, (0..<4).map(component) + [1]) ?? .black
        case .icc(let space, let n): return Self.converted(space, (0..<n).map(component) + [1]) ?? .black
        case .lab(let space): return Self.converted(space, (0..<3).map(component) + [1]) ?? .black
        case let .indexed(base, high, table):
            let count = base.componentCount, index = min(max(pdfInt(component(0)), 0), high)
            guard (index + 1) * count <= table.count else { return .black }
            let raw = table[(index * count)..<((index + 1) * count)].map { CGFloat($0) / 255 }
            return base.color(base.decoded(raw))
        case let .tint(n, alternate, function, _):
            guard let function else { return Self.fallback(n, components) }
            return alternate.color(function.evaluate((0..<n).map(component)))
        case .pattern: return .black
        }
    }

    /// A tint with no usable transform: darker with more ink, so the mark stays visible.
    private static func fallback(_ n: Int, _ components: [CGFloat]) -> SVGColor {
        let value = 1 - max(0, min(1, components.prefix(n).max() ?? 1))
        return SVGColor(red: value, green: value, blue: value)
    }

    /// Lookup-table bytes (0…1 per byte) back to a colour's natural range.
    private func decoded(_ raw: [CGFloat]) -> [CGFloat] {
        guard case .lab = self, raw.count == 3 else { return raw }
        return [raw[0] * 100, raw[1] * 255 - 128, raw[2] * 255 - 128]
    }

    private static func converted(_ space: CGColorSpace, _ components: [CGFloat]) -> SVGColor? {
        guard space.numberOfComponents + 1 == components.count,
              let color = CGColor(colorSpace: space, components: components),
              let srgb = color.converted(to: sRGB, intent: .relativeColorimetric, options: nil),
              let out = srgb.components, out.count >= 3 else { return nil }
        return SVGColor(red: out[0], green: out[1], blue: out[2])
    }

    /// The Quartz colour space for image samples, when there is one.
    var imageSpace: CGColorSpace? {
        switch self {
        case .gray: return CGColorSpaceCreateDeviceGray()
        case .rgb: return Self.sRGB
        case .cmyk: return Self.genericCMYK
        case .icc(let space, _), .lab(let space): return space
        case let .indexed(base, high, table):
            guard let baseSpace = base.imageSpace, (high + 1) * base.componentCount <= table.count else { return nil }
            return table.withUnsafeBufferPointer { CGColorSpace(indexedBaseSpace: baseSpace, last: high, colorTable: $0.baseAddress!) }
        case let .tint(1, alternate, function?, false):
            var table = [UInt8]()
            table.reserveCapacity(768)
            for level in 0...255 {
                let color = alternate.color(function.evaluate([CGFloat(level) / 255]))
                table += [color.r, color.g, color.b]
            }
            return table.withUnsafeBufferPointer { CGColorSpace(indexedBaseSpace: Self.sRGB, last: 255, colorTable: $0.baseAddress!) }
        default: return nil
        }
    }

    var isDeviceLikeForJPEG: Bool {
        switch self {
        case .gray, .rgb: return true
        case .icc(_, let n): return n == 1 || n == 3
        default: return false
        }
    }
}

// MARK: - Fonts

/// Adobe glyph names for the Latin characters the base encodings can reach, as "name hexcode" pairs.
fileprivate let glyphNameTable: [String: UInt32] = {
    let table = """
    space 20 exclam 21 quotedbl 22 numbersign 23 dollar 24 percent 25 ampersand 26 quotesingle 27 parenleft 28 parenright 29 asterisk 2A plus 2B
    comma 2C hyphen 2D period 2E slash 2F zero 30 one 31 two 32 three 33 four 34 five 35 six 36 seven 37 eight 38 nine 39 colon 3A semicolon 3B
    less 3C equal 3D greater 3E question 3F at 40 bracketleft 5B backslash 5C bracketright 5D asciicircum 5E underscore 5F grave 60 braceleft 7B
    bar 7C braceright 7D asciitilde 7E exclamdown A1 cent A2 sterling A3 currency A4 yen A5 brokenbar A6 section A7 dieresis A8 copyright A9
    ordfeminine AA guillemotleft AB logicalnot AC registered AE macron AF degree B0 plusminus B1 twosuperior B2 threesuperior B3 acute B4
    mu B5 paragraph B6 periodcentered B7 cedilla B8 onesuperior B9 ordmasculine BA guillemotright BB onequarter BC onehalf BD threequarters BE
    questiondown BF Agrave C0 Aacute C1 Acircumflex C2 Atilde C3 Adieresis C4 Aring C5 AE C6 Ccedilla C7 Egrave C8 Eacute C9 Ecircumflex CA
    Edieresis CB Igrave CC Iacute CD Icircumflex CE Idieresis CF Eth D0 Ntilde D1 Ograve D2 Oacute D3 Ocircumflex D4 Otilde D5 Odieresis D6
    multiply D7 Oslash D8 Ugrave D9 Uacute DA Ucircumflex DB Udieresis DC Yacute DD Thorn DE germandbls DF agrave E0 aacute E1 acircumflex E2
    atilde E3 adieresis E4 aring E5 ae E6 ccedilla E7 egrave E8 eacute E9 ecircumflex EA edieresis EB igrave EC iacute ED icircumflex EE
    idieresis EF eth F0 ntilde F1 ograve F2 oacute F3 ocircumflex F4 otilde F5 odieresis F6 divide F7 oslash F8 ugrave F9 uacute FA
    ucircumflex FB udieresis FC yacute FD thorn FE ydieresis FF dotlessi 131 Lslash 141 lslash 142 OE 152 oe 153 Scaron 160 scaron 161
    Ydieresis 178 Zcaron 17D zcaron 17E florin 192 circumflex 2C6 caron 2C7 breve 2D8 dotaccent 2D9 ring 2DA ogonek 2DB tilde 2DC
    hungarumlaut 2DD endash 2013 emdash 2014 quoteleft 2018 quoteright 2019 quotesinglbase 201A quotedblleft 201C quotedblright 201D
    quotedblbase 201E dagger 2020 daggerdbl 2021 bullet 2022 ellipsis 2026 perthousand 2030 guilsinglleft 2039 guilsinglright 203A
    fraction 2044 Euro 20AC trademark 2122 minus 2212 fi FB01 fl FB02
    """
    var map: [String: UInt32] = [:]
    let parts = table.split(whereSeparator: \.isWhitespace).map(String.init)
    for index in stride(from: 0, to: parts.count - 1, by: 2) { map[parts[index]] = UInt32(parts[index + 1], radix: 16) }
    for scalar in 0x41...0x5A { map[String(UnicodeScalar(UInt8(scalar)))] = UInt32(scalar) }
    for scalar in 0x61...0x7A { map[String(UnicodeScalar(UInt8(scalar)))] = UInt32(scalar) }
    return map
}()

fileprivate let unicodeGlyphNames: [UInt32: String] = {
    var map: [UInt32: String] = [:]
    for (name, value) in glyphNameTable { map[value] = name }
    return map
}()

fileprivate func unicodeForGlyphName(_ name: String) -> UInt32? {
    if let value = glyphNameTable[name] { return value }
    let base = name.split(separator: ".").first.map(String.init) ?? name
    if base != name, let value = glyphNameTable[base] { return value }
    if base.hasPrefix("uni"), base.count >= 7 { return UInt32(base.dropFirst(3).prefix(4), radix: 16) }
    if base.hasPrefix("u"), base.count >= 5 { return UInt32(base.dropFirst(), radix: 16) }
    return nil
}

/// StandardEncoding: ASCII except two quotes, plus the upper half as (code, name).
fileprivate let standardEncodingNames: [String?] = {
    var names = [String?](repeating: nil, count: 256)
    for code in 32...126 { names[code] = unicodeGlyphNames[UInt32(code)] }
    names[39] = "quoteright"; names[96] = "quoteleft"
    let upper: [(Int, String)] = [
        (161, "exclamdown"), (162, "cent"), (163, "sterling"), (164, "fraction"), (165, "yen"), (166, "florin"), (167, "section"),
        (168, "currency"), (169, "quotesingle"), (170, "quotedblleft"), (171, "guillemotleft"), (172, "guilsinglleft"), (173, "guilsinglright"),
        (174, "fi"), (175, "fl"), (177, "endash"), (178, "dagger"), (179, "daggerdbl"), (180, "periodcentered"), (182, "paragraph"),
        (183, "bullet"), (184, "quotesinglbase"), (185, "quotedblbase"), (186, "quotedblright"), (187, "guillemotright"), (188, "ellipsis"),
        (189, "perthousand"), (191, "questiondown"), (193, "grave"), (194, "acute"), (195, "circumflex"), (196, "tilde"), (197, "macron"),
        (198, "breve"), (199, "dotaccent"), (200, "dieresis"), (202, "ring"), (203, "cedilla"), (205, "hungarumlaut"), (206, "ogonek"),
        (207, "caron"), (208, "emdash"), (225, "AE"), (227, "ordfeminine"), (232, "Lslash"), (233, "Oslash"), (234, "OE"), (235, "ordmasculine"),
        (241, "ae"), (245, "dotlessi"), (248, "lslash"), (249, "oslash"), (250, "oe"), (251, "germandbls"),
    ]
    for (code, name) in upper { names[code] = name }
    return names
}()

fileprivate func baseEncodingNames(_ name: String?) -> [String?]? {
    let encoding: String.Encoding
    switch name {
    case "WinAnsiEncoding": encoding = .windowsCP1252
    case "MacRomanEncoding": encoding = .macOSRoman
    case "StandardEncoding": return standardEncodingNames
    default: return nil
    }
    return (0...255).map { code -> String? in
        guard code >= 32, let text = String(bytes: [UInt8(code)], encoding: encoding), let scalar = text.unicodeScalars.first else { return nil }
        return unicodeGlyphNames[scalar.value]
    }
}

/// `cmap` subtables of an sfnt file (formats 0, 4, 6, 12).
fileprivate struct CMapTables {
    private var maps: [UInt32: [UInt32: UInt16]] = [:]

    init(table: Data) {
        let d = [UInt8](table)
        func u16(_ o: Int) -> Int { o + 1 < d.count ? Int(d[o]) << 8 | Int(d[o + 1]) : 0 }
        func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }
        for index in 0..<u16(2) {
            let record = 4 + index * 8, platform = u16(record), encoding = u16(record + 2), offset = u32(record + 4)
            guard offset < d.count else { continue }
            var map: [UInt32: UInt16] = [:]
            switch u16(offset) {
            case 0:
                for code in 0..<256 where offset + 6 + code < d.count { map[UInt32(code)] = UInt16(d[offset + 6 + code]) }
            case 4:
                let segments = u16(offset + 6) / 2
                let ends = offset + 14, starts = ends + segments * 2 + 2, deltas = starts + segments * 2, ranges = deltas + segments * 2
                for segment in 0..<segments {
                    let end = u16(ends + segment * 2), start = u16(starts + segment * 2), delta = u16(deltas + segment * 2), range = u16(ranges + segment * 2)
                    guard start <= end, start != 0xFFFF else { continue }
                    for code in start...min(end, 0xFFFE) {
                        var glyph: Int
                        if range == 0 { glyph = (code + delta) & 0xFFFF } else {
                            glyph = u16(ranges + segment * 2 + range + (code - start) * 2)
                            if glyph != 0 { glyph = (glyph + delta) & 0xFFFF }
                        }
                        if glyph != 0 { map[UInt32(code)] = UInt16(glyph) }
                    }
                }
            case 6:
                let first = u16(offset + 6), count = u16(offset + 8)
                for index in 0..<count { let glyph = u16(offset + 10 + index * 2); if glyph != 0 { map[UInt32(first + index)] = UInt16(glyph) } }
            case 12:
                let groups = u32(offset + 12)
                guard groups < 100_000 else { continue }
                for group in 0..<groups {
                    let record = offset + 16 + group * 12, start = u32(record), end = u32(record + 4), glyph = u32(record + 8)
                    guard start <= end, end - start < 70_000 else { continue }
                    for code in start...end { map[UInt32(code)] = UInt16(truncatingIfNeeded: glyph + code - start) }
                }
            default: continue
            }
            maps[UInt32(platform) << 16 | UInt32(encoding)] = map
        }
    }

    var unicode: [UInt32: UInt16]? { maps[0x30001] ?? maps[0x3000A] ?? maps[0x00003] ?? maps[0x00004] ?? maps[0x00000] }
    var symbol: [UInt32: UInt16]? { maps[0x30000] }
    var macRoman: [UInt32: UInt16]? { maps[0x10000] }
}

/// The small part of a CFF table that Quartz doesn't expose: CID↔glyph mapping and the built-in encoding.
fileprivate struct CFFInfo {
    var isCID = false
    var cidToGlyph: [Int: CGGlyph] = [:]
    var builtInEncoding: [Int: CGGlyph] = [:]
    var usesStandardEncoding = false

    init?(_ data: Data) {
        var bytes = [UInt8](data)
        if bytes.count > 12, bytes[0...3] == [0x4F, 0x54, 0x54, 0x4F] {
            guard let table = CFFInfo.sfntTable(bytes, "CFF ") else { return nil }
            bytes = table
        }
        guard bytes.count > 4, bytes[0] == 1 else { return nil }
        let d = bytes
        func u16(_ o: Int) -> Int { o + 1 < d.count ? Int(d[o]) << 8 | Int(d[o + 1]) : 0 }
        func indexEnd(_ start: Int) -> (end: Int, items: [(Int, Int)]) {
            let count = u16(start)
            guard count > 0, start + 2 < d.count else { return (start + 2, []) }
            let size = Int(d[start + 2])
            guard (1...4).contains(size), start + 3 + (count + 1) * size <= d.count else { return (start + 2, []) }
            func offset(_ i: Int) -> Int { (0..<size).reduce(0) { $0 << 8 | Int(d[start + 3 + i * size + $1]) } }
            let base = start + 3 + (count + 1) * size - 1
            let items = (0..<count).map { (base + offset($0), base + offset($0 + 1)) }
            return (base + offset(count), items)
        }
        let names = indexEnd(Int(d[2]))
        let top = indexEnd(names.end)
        guard let range = top.items.first, range.1 <= d.count else { return nil }
        var operands: [Int] = []
        var ops: [Int: [Int]] = [:]
        var i = range.0
        while i < range.1 {
            let b = Int(d[i])
            switch b {
            case 0...21:
                var op = b; i += 1
                if b == 12, i < range.1 { op = 1200 + Int(d[i]); i += 1 }
                ops[op] = operands; operands = []
            case 28: operands.append(Int(Int16(truncatingIfNeeded: u16(i + 1)))); i += 3
            case 29: operands.append(Int(Int32(truncatingIfNeeded: u16(i + 1) << 16 | u16(i + 3)))); i += 5
            case 30:
                i += 1
                scan: while i < range.1 { let v = d[i]; i += 1; if v & 0xF == 0xF || v >> 4 == 0xF { break scan } }
                operands.append(0)
            case 32...246: operands.append(b - 139); i += 1
            case 247...250: operands.append((b - 247) * 256 + Int(i + 1 < d.count ? d[i + 1] : 0) + 108); i += 2
            case 251...254: operands.append(-(b - 251) * 256 - Int(i + 1 < d.count ? d[i + 1] : 0) - 108); i += 2
            default: i += 1
            }
        }
        guard let charStrings = ops[17]?.first else { return nil }
        let glyphCount = u16(charStrings)
        isCID = ops[1230] != nil
        let charset = ops[15]?.first ?? 0
        var ids = [Int](repeating: 0, count: max(glyphCount, 1))
        if charset > 2, charset < d.count {
            var offset = charset + 1, glyph = 1
            switch d[charset] {
            case 0:
                while glyph < glyphCount { ids[glyph] = u16(offset); offset += 2; glyph += 1 }
            case 1, 2:
                let wide = d[charset] == 2
                while glyph < glyphCount, offset + 2 < d.count {
                    let first = u16(offset), left = wide ? u16(offset + 2) : Int(d[offset + 2])
                    offset += wide ? 4 : 3
                    for delta in 0...left where glyph < glyphCount { ids[glyph] = first + delta; glyph += 1 }
                }
            default: break
            }
        } else if isCID {
            ids = Array(0..<max(glyphCount, 1))
        }
        if isCID { for (glyph, cid) in ids.enumerated() { cidToGlyph[cid] = CGGlyph(truncatingIfNeeded: glyph) } }
        let encoding = ops[16]?.first ?? 0
        if isCID { return }
        if encoding == 0 { usesStandardEncoding = true } else if encoding > 1, encoding < d.count {
            let format = d[encoding] & 0x7F
            var glyph = 1, offset = encoding + 2
            if format == 0 {
                for _ in 0..<Int(d[encoding + 1]) where offset < d.count { builtInEncoding[Int(d[offset])] = CGGlyph(glyph); offset += 1; glyph += 1 }
            } else if format == 1 {
                for _ in 0..<Int(d[encoding + 1]) where offset + 1 < d.count {
                    for delta in 0...Int(d[offset + 1]) { builtInEncoding[Int(d[offset]) + delta] = CGGlyph(glyph); glyph += 1 }
                    offset += 2
                }
            }
        }
    }

    static func sfntTable(_ bytes: [UInt8], _ tag: String) -> [UInt8]? {
        let want = Array(tag.utf8)
        func u32(_ o: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(bytes[o + $1]) } }
        let count = Int(bytes[4]) << 8 | Int(bytes[5])
        for index in 0..<count where 12 + index * 16 + 16 <= bytes.count {
            let record = 12 + index * 16
            guard Array(bytes[record..<(record + 4)]) == want else { continue }
            let offset = u32(record + 8), length = u32(record + 12)
            guard offset + length <= bytes.count else { return nil }
            return Array(bytes[offset..<(offset + length)])
        }
        return nil
    }
}

/// Type 1 (`FontFile`) programs, which Quartz can't load: eexec, charstring decryption, and outline interpretation.
fileprivate final class Type1Program {
    private var charStrings: [String: [UInt8]] = [:]
    private var subrs: [Int: [UInt8]] = [:]
    private var encoding: [Int: String] = [:]
    private var matrix = CGAffineTransform(scaleX: 0.001, y: 0.001)
    private var cache: [String: CGPath?] = [:]
    var usesStandardEncoding = true

    init?(_ input: Data) {
        var bytes = Self.stripPFB([UInt8](input))
        guard let marker = Self.find(bytes, "eexec", from: 0) else { return nil }
        let clear = String(decoding: bytes[..<marker], as: UTF8.self)
        parseClearText(clear)
        var start = marker + 5
        while start < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[start]) { start += 1 }
        guard start + 4 <= bytes.count else { return nil }
        if bytes[start..<(start + 4)].allSatisfy({ Self.hexValue($0) != nil }) {
            var nibbles: [UInt8] = []
            for byte in bytes[start...] { if let value = Self.hexValue(byte) { nibbles.append(value) } }
            bytes = stride(from: 0, to: nibbles.count - 1, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
        } else {
            bytes = Array(bytes[start...])
        }
        let privateBytes = Self.decrypt(bytes, key: 55665, skip: 4)
        guard parsePrivate(privateBytes), !charStrings.isEmpty else { return nil }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x37
        case 0x61...0x66: return byte - 0x57
        default: return nil
        }
    }

    private static func stripPFB(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count > 6, bytes[0] == 0x80 else { return bytes }
        var out: [UInt8] = [], offset = 0
        while offset + 6 <= bytes.count, bytes[offset] == 0x80, bytes[offset + 1] != 3 {
            let length = Int(bytes[offset + 2]) | Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4]) << 16 | Int(bytes[offset + 5]) << 24
            let end = min(offset + 6 + length, bytes.count)
            out += bytes[(offset + 6)..<end]
            offset = end
        }
        return out
    }

    private static func find(_ bytes: [UInt8], _ text: String, from start: Int) -> Int? {
        let needle = Array(text.utf8)
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        for index in start...(bytes.count - needle.count) where bytes[index] == needle[0] && Array(bytes[index..<(index + needle.count)]) == needle { return index }
        return nil
    }

    private static func decrypt(_ bytes: [UInt8], key: UInt16, skip: Int) -> [UInt8] {
        var r = key, out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            out.append(byte ^ UInt8(r >> 8))
            r = (UInt16(byte) &+ r) &* 52845 &+ 22719
        }
        return Array(out.dropFirst(skip))
    }

    private func parseClearText(_ text: String) {
        if let range = text.range(of: "/FontMatrix"), let open = text[range.upperBound...].firstIndex(of: "["), let close = text[open...].firstIndex(of: "]") {
            let values = text[text.index(after: open)..<close].split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            if values.count == 6 { matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]) }
        }
        guard let range = text.range(of: "/Encoding") else { return }
        let rest = text[range.upperBound...]
        if rest.hasPrefix(" StandardEncoding") || rest.prefix(30).contains("StandardEncoding") { return }
        usesStandardEncoding = false
        let tokens = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        var index = 0
        while index + 3 < tokens.count {
            if tokens[index] == "def" || tokens[index] == "readonly" { break }
            if tokens[index] == "dup", let code = Int(tokens[index + 1]), tokens[index + 2].hasPrefix("/") {
                encoding[code] = String(tokens[index + 2].dropFirst())
                index += 3
            }
            index += 1
        }
    }

    private func parsePrivate(_ data: [UInt8]) -> Bool {
        var lenIV = 4
        if let at = Self.find(data, "/lenIV", from: 0), let (value, _) = readInt(data, at + 6) { lenIV = value }
        func readBinary(_ start: Int) -> (bytes: [UInt8], next: Int)? {
            guard let (length, afterLength) = readInt(data, start) else { return nil }
            var i = skipSpace(data, afterLength)
            while i < data.count, data[i] > 0x20 { i += 1 }
            i += 1
            guard length >= 0, i + length <= data.count else { return nil }
            let decoded = lenIV >= 0 ? Self.decrypt(Array(data[i..<(i + length)]), key: 4330, skip: lenIV) : Array(data[i..<(i + length)])
            return (decoded, i + length)
        }
        if let subrsAt = Self.find(data, "/Subrs", from: 0) {
            var i = subrsAt + 6
            let limit = Self.find(data, "/CharStrings", from: i) ?? data.count
            while let dup = Self.find(data, "dup ", from: i), dup < limit {
                guard let (index, next) = readInt(data, dup + 4), let (bytes, after) = readBinary(next) else { i = dup + 4; continue }
                subrs[index] = bytes
                i = after
            }
        }
        guard let start = Self.find(data, "/CharStrings", from: 0) else { return false }
        var i = start + 12
        while i < data.count {
            guard data[i] == 0x2F else {
                if data[i] == 0x65, i + 3 <= data.count, Array(data[i..<(i + 3)]) == Array("end".utf8) { break }
                i += 1
                continue
            }
            var nameEnd = i + 1
            while nameEnd < data.count, data[nameEnd] > 0x20, data[nameEnd] != 0x2F { nameEnd += 1 }
            let name = String(decoding: data[(i + 1)..<nameEnd], as: UTF8.self)
            guard let (bytes, after) = readBinary(nameEnd) else { i = nameEnd; continue }
            charStrings[name] = bytes
            i = after
        }
        return true
    }

    private func skipSpace(_ data: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < data.count, data[i] <= 0x20 { i += 1 }
        return i
    }

    private func readInt(_ data: [UInt8], _ start: Int) -> (Int, Int)? {
        var i = skipSpace(data, start), value = 0, digits = 0
        while i < data.count, (0x30...0x39).contains(data[i]) { value = value * 10 + Int(data[i] - 0x30); i += 1; digits += 1; if digits > 9 { return nil } }
        return digits > 0 ? (value, i) : nil
    }

    func encodedName(_ code: Int) -> String? { encoding[code] }
    func hasGlyph(_ name: String) -> Bool { charStrings[name] != nil }

    func outline(_ name: String) -> CGPath? {
        if let cached = cache[name] { return cached }
        var runner = Runner(program: self)
        let path = runner.run(name) ? runner.path.copy(using: &matrix) : nil
        cache[name] = path
        return path
    }

    private struct Runner {
        let program: Type1Program
        let path = CGMutablePath()
        var stack: [CGFloat] = [], postscript: [CGFloat] = []
        var x: CGFloat = 0, y: CGFloat = 0, sideBearingX: CGFloat = 0
        var open = false, flexing = false, flex: [CGPoint] = [], steps = 0, finished = false

        mutating func run(_ name: String) -> Bool {
            guard let code = program.charStrings[name] else { return false }
            return execute(code, depth: 0)
        }

        private mutating func moveBy(_ dx: CGFloat, _ dy: CGFloat) {
            x += dx; y += dy
            if flexing { flex.append(CGPoint(x: x, y: y)); return }
            if open { path.closeSubpath() }
            path.move(to: CGPoint(x: x, y: y))
            open = true
        }

        private mutating func lineBy(_ dx: CGFloat, _ dy: CGFloat) {
            x += dx; y += dy
            if !open { path.move(to: CGPoint(x: x, y: y)); open = true } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }

        private mutating func curveBy(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ e: CGFloat, _ f: CGFloat) {
            let p1 = CGPoint(x: x + a, y: y + b), p2 = CGPoint(x: p1.x + c, y: p1.y + d), p3 = CGPoint(x: p2.x + e, y: p2.y + f)
            if !open { path.move(to: CGPoint(x: x, y: y)); open = true }
            path.addCurve(to: p3, control1: p1, control2: p2)
            x = p3.x; y = p3.y
        }

        private mutating func execute(_ code: [UInt8], depth: Int) -> Bool {
            guard depth < 12 else { return false }
            var i = 0
            while i < code.count, !finished {
                steps += 1
                guard steps < 200_000 else { return false }
                let v = Int(code[i]); i += 1
                switch v {
                case 32...246: stack.append(CGFloat(v - 139))
                case 247...250: guard i < code.count else { return false }; stack.append(CGFloat((v - 247) * 256 + Int(code[i]) + 108)); i += 1
                case 251...254: guard i < code.count else { return false }; stack.append(CGFloat(-(v - 251) * 256 - Int(code[i]) - 108)); i += 1
                case 255:
                    guard i + 4 <= code.count else { return false }
                    stack.append(CGFloat(Int32(bitPattern: UInt32(code[i]) << 24 | UInt32(code[i + 1]) << 16 | UInt32(code[i + 2]) << 8 | UInt32(code[i + 3]))))
                    i += 4
                case 1, 3: stack = []
                case 4: guard let dy = stack.last else { return false }; moveBy(0, dy); stack = []
                case 5: guard stack.count >= 2 else { return false }; lineBy(stack[0], stack[1]); stack = []
                case 6: guard stack.count >= 1 else { return false }; lineBy(stack[0], 0); stack = []
                case 7: guard stack.count >= 1 else { return false }; lineBy(0, stack[0]); stack = []
                case 8: guard stack.count >= 6 else { return false }; curveBy(stack[0], stack[1], stack[2], stack[3], stack[4], stack[5]); stack = []
                case 9: if open { path.closeSubpath(); open = false }; stack = []
                case 10:
                    guard let index = stack.popLast(), let subr = program.subrs[pdfInt(index)] else { return false }
                    if !execute(subr, depth: depth + 1) { return false }
                case 11: return true
                case 13:
                    guard stack.count >= 2 else { return false }
                    sideBearingX = stack[0]; x = stack[0]; y = 0; stack = []
                case 14:
                    if open { path.closeSubpath(); open = false }
                    finished = true
                case 21: guard stack.count >= 2 else { return false }; moveBy(stack[0], stack[1]); stack = []
                case 22: guard stack.count >= 1 else { return false }; moveBy(stack[0], 0); stack = []
                case 30: guard stack.count >= 4 else { return false }; curveBy(0, stack[0], stack[1], stack[2], stack[3], 0); stack = []
                case 31: guard stack.count >= 4 else { return false }; curveBy(stack[0], 0, stack[1], stack[2], 0, stack[3]); stack = []
                case 12:
                    guard i < code.count else { return false }
                    let e = code[i]; i += 1
                    switch e {
                    case 0, 1, 2: stack = []
                    case 6:
                        guard stack.count >= 5, depth < 4 else { return false }
                        let asb = stack[0], adx = stack[1], ady = stack[2], bchar = pdfInt(stack[3]), achar = pdfInt(stack[4])
                        stack = []
                        guard let base = standardEncodingNames[safe: bchar] ?? nil, let accent = standardEncodingNames[safe: achar] ?? nil,
                              let baseCode = program.charStrings[base], let accentCode = program.charStrings[accent] else { return false }
                        let startBearing = sideBearingX
                        if !execute(baseCode, depth: depth + 1) { return false }
                        if open { path.closeSubpath(); open = false }
                        finished = false; stack = []
                        var accentRunner = Runner(program: program)
                        accentRunner.steps = steps
                        guard accentRunner.execute(accentCode, depth: depth + 1) else { return false }
                        steps = accentRunner.steps
                        path.addPath(accentRunner.path, transform: CGAffineTransform(translationX: startBearing + adx - asb, y: ady))
                        finished = true
                    case 7:
                        guard stack.count >= 4 else { return false }
                        sideBearingX = stack[0]; x = stack[0]; y = stack[1]; stack = []
                    case 12:
                        guard stack.count >= 2 else { return false }
                        let b = stack.removeLast(), a = stack.removeLast()
                        stack.append(b == 0 ? 0 : a / b)
                    case 16:
                        guard stack.count >= 2 else { return false }
                        let which = pdfInt(stack.removeLast()), count = pdfInt(stack.removeLast())
                        guard count >= 0, stack.count >= count else { return false }
                        let arguments = Array(stack.suffix(count))
                        stack.removeLast(count)
                        postscript = arguments.reversed()
                        switch which {
                        case 1: flexing = true; flex = []
                        case 2: break
                        case 0:
                            flexing = false
                            if flex.count >= 7 {
                                if !open { path.move(to: flex[0]); open = true }
                                path.addCurve(to: flex[3], control1: flex[1], control2: flex[2])
                                path.addCurve(to: flex[6], control1: flex[4], control2: flex[5])
                                x = flex[6].x; y = flex[6].y
                            }
                            if arguments.count >= 3 { postscript = [arguments[2], arguments[1]] }
                        case 3: postscript = [3]
                        default: break
                        }
                    case 17: stack.append(postscript.popLast() ?? 0)
                    case 33: guard stack.count >= 2 else { return false }; x = stack[0]; y = stack[1]; stack = []
                    default: stack = []
                    }
                default: stack = []
                }
            }
            return true
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Character-code → CID (or Unicode) mapping from an embedded CMap or a ToUnicode CMap.
fileprivate struct ParsedCMap {
    var spaces: [(length: Int, low: UInt32, high: UInt32)] = []
    var cidRanges: [(low: UInt32, high: UInt32, cid: Int)] = []
    var cids: [UInt32: Int] = [:]
    var unicode: [UInt32: UInt32] = [:]
    var vertical = false

    init(_ data: Data) {
        var tokens: [Substring] = []
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<<", with: " ").replacingOccurrences(of: ">>", with: " ")
            .replacingOccurrences(of: "[", with: " [ ").replacingOccurrences(of: "]", with: " ] ").replacingOccurrences(of: "<", with: " <").replacingOccurrences(of: ">", with: " ")
        tokens = text.split(whereSeparator: \.isWhitespace)
        func hex(_ t: Substring) -> (value: UInt32, length: Int)? {
            guard t.hasPrefix("<") else { return nil }
            let body = t.dropFirst()
            guard !body.isEmpty, body.count <= 8, let value = UInt32(body, radix: 16) else { return nil }
            return (value, (body.count + 1) / 2)
        }
        func utf16(_ t: Substring) -> UInt32? {
            guard t.hasPrefix("<") else { return nil }
            let body = Array(t.dropFirst().utf8)
            guard body.count >= 4 else { return UInt32(t.dropFirst(), radix: 16) }
            let first = UInt32(String(decoding: body[0..<4], as: UTF8.self), radix: 16) ?? 0
            if (0xD800...0xDBFF).contains(first), body.count >= 8, let second = UInt32(String(decoding: body[4..<8], as: UTF8.self), radix: 16) {
                return 0x10000 + (first - 0xD800) << 10 + (second &- 0xDC00)
            }
            return first
        }
        var i = 0
        while i < tokens.count {
            let token = tokens[i]; i += 1
            switch token {
            case "/WMode": if i < tokens.count, tokens[i] == "1" { vertical = true }
            case "begincodespacerange":
                while i + 1 < tokens.count, tokens[i] != "endcodespacerange" {
                    if let low = hex(tokens[i]), let high = hex(tokens[i + 1]) { spaces.append((low.length, low.value, high.value)) }
                    i += 2
                }
            case "begincidrange":
                while i + 2 < tokens.count, tokens[i] != "endcidrange" {
                    if let low = hex(tokens[i]), let high = hex(tokens[i + 1]), let cid = Int(tokens[i + 2]) { cidRanges.append((low.value, high.value, cid)) }
                    i += 3
                }
            case "begincidchar":
                while i + 1 < tokens.count, tokens[i] != "endcidchar" {
                    if let code = hex(tokens[i]), let cid = Int(tokens[i + 1]) { cids[code.value] = cid }
                    i += 2
                }
            case "beginbfchar":
                while i + 1 < tokens.count, tokens[i] != "endbfchar" {
                    if let code = hex(tokens[i]), let scalar = utf16(tokens[i + 1]) { unicode[code.value] = scalar }
                    i += 2
                }
            case "beginbfrange":
                while i + 2 < tokens.count, tokens[i] != "endbfrange" {
                    guard let low = hex(tokens[i]), let high = hex(tokens[i + 1]) else { i += 1; continue }
                    if tokens[i + 2] == "[" {
                        i += 3
                        var code = low.value
                        while i < tokens.count, tokens[i] != "]" {
                            if let scalar = utf16(tokens[i]) { unicode[code] = scalar }
                            code &+= 1; i += 1
                        }
                        i += 1
                    } else {
                        if let start = utf16(tokens[i + 2]), high.value >= low.value, high.value - low.value < 70_000 {
                            for code in low.value...high.value { unicode[code] = start + (code - low.value) }
                        }
                        i += 3
                    }
                }
            default: break
            }
        }
    }

    func cid(_ code: UInt32) -> Int? {
        if let cid = cids[code] { return cid }
        for range in cidRanges where code >= range.low && code <= range.high { return range.cid + Int(code - range.low) }
        return nil
    }

    var maxLength: Int { spaces.map(\.length).max() ?? 2 }
}

/// One font from a page's resources: how to read codes, how far each advances, and where its outlines come from.
fileprivate final class SVGFont {
    enum Kind { case simple, composite, type3 }
    var kind: Kind = .simple

    var ctFont: CTFont?
    var type1: Type1Program?
    var cff: CFFInfo?
    var cmaps: CMapTables?
    var substitute = false
    var isSymbolFont = false

    var widths: [Int: CGFloat] = [:]
    var defaultWidth: CGFloat = 0
    var widthsKnown = false
    var names = [String?](repeating: nil, count: 256)
    var hasEncoding = false

    var encodingCMap: ParsedCMap?
    var identityCMap = false
    var unicodeCMapName = false
    var cmapUnknown = false
    var vertical = false
    var verticalOrigin: CGFloat = 880
    var verticalAdvance: CGFloat = -1000
    var cidToGID: [UInt8]?
    var toUnicode: [UInt32: UInt32] = [:]

    var type3Procs: CGPDFDictionaryRef?
    var type3Matrix = CGAffineTransform(a: 0.001, b: 0, c: 0, d: 0.001, tx: 0, ty: 0)
    var type3Resources: CGPDFDictionaryRef?

    private var outlines: [Int: (path: CGPath?, known: Bool)] = [:]

    init(_ dictionary: CGPDFDictionaryRef) {
        switch pdfName(dictionary, "Subtype") {
        case "Type0": kind = .composite; loadComposite(dictionary)
        case "Type3": kind = .type3; loadType3(dictionary)
        default: loadSimple(dictionary)
        }
    }

    // MARK: Loading

    private static func strippedName(_ name: String?) -> String {
        var text = name ?? ""
        if text.count > 7, text.dropFirst(6).first == "+" { text = String(text.dropFirst(7)) }
        return text
    }

    /// Embedded program in a FontDescriptor, loaded into Quartz or the Type 1 interpreter.
    private func loadProgram(_ descriptor: CGPDFDictionaryRef?) {
        guard let descriptor else { return }
        if let stream = pdfStream(descriptor, "FontFile"), let data = pdfData(stream)?.data {
            type1 = Type1Program(data)
            return
        }
        for key in ["FontFile2", "FontFile3"] {
            guard let stream = pdfStream(descriptor, key), let data = pdfData(stream)?.data else { continue }
            guard let provider = CGDataProvider(data: data as CFData), let graphicsFont = CGFont(provider) else { continue }
            ctFont = CTFontCreateWithGraphicsFont(graphicsFont, 1, nil, nil)
            if key == "FontFile2" {
                if let table = CFontTable(data, "cmap") { cmaps = CMapTables(table: table) }
            } else {
                cff = CFFInfo(data)
                if let table = CFontTable(data, "cmap") { cmaps = CMapTables(table: table) }
            }
            return
        }
    }

    private func CFontTable(_ data: Data, _ tag: String) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { return nil }
        return CFFInfo.sfntTable(bytes, tag).map { Data($0) }
    }

    /// A Mac font standing in for one that isn't embedded.
    private func loadSubstitute(_ baseFont: String, descriptor: CGPDFDictionaryRef?) {
        substitute = true
        let name = Self.strippedName(baseFont)
        let lower = name.lowercased().replacingOccurrences(of: " ", with: "")
        let flags = descriptor.flatMap { pdfNumber($0, "Flags") }.map(pdfInt) ?? 0
        isSymbolFont = lower == "symbol" || lower.hasPrefix("zapfdingbats") || lower.hasPrefix("dingbats")
        let bold = lower.contains("bold") || lower.contains("black") || lower.contains("heavy") || lower.contains("demi")
        let italic = lower.contains("italic") || lower.contains("oblique") || flags & 64 != 0
        let mono = lower.contains("courier") || flags & 1 != 0
        let serif = !mono && (lower.contains("times") || lower.contains("georgia") || lower.contains("garamond") || lower.contains("serif") && !lower.contains("sans") || flags & 2 != 0)
        let wanted: String
        if lower == "symbol" { wanted = "Symbol" } else if lower.hasPrefix("zapfdingbats") || lower.hasPrefix("dingbats") { wanted = "ZapfDingbatsITC" } else {
            let family = name.replacingOccurrences(of: ",", with: "-")
            let candidate = CTFontCreateWithName(family as CFString, 1, nil)
            let resolved = CTFontCopyPostScriptName(candidate) as String
            let requested = family.lowercased().replacingOccurrences(of: "-", with: "")
            if resolved.lowercased().replacingOccurrences(of: "-", with: "").hasPrefix(requested) || requested.hasPrefix(resolved.lowercased().replacingOccurrences(of: "-", with: "")) {
                wanted = resolved
            } else if mono {
                wanted = "Courier" + (bold && italic ? "-BoldOblique" : bold ? "-Bold" : italic ? "-Oblique" : "")
            } else if serif {
                wanted = "Times-" + (bold && italic ? "BoldItalic" : bold ? "Bold" : italic ? "Italic" : "Roman")
            } else {
                wanted = "Helvetica" + (bold && italic ? "-BoldOblique" : bold ? "-Bold" : italic ? "-Oblique" : "")
            }
        }
        let font = CTFontCreateWithName(wanted as CFString, 1, nil)
        ctFont = font
        if isSymbolFont, let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableCmap), []) { cmaps = CMapTables(table: table as Data) }
    }

    private func loadSimple(_ dictionary: CGPDFDictionaryRef) {
        let descriptor = pdfDictionary(dictionary, "FontDescriptor")
        let baseFont = pdfName(dictionary, "BaseFont") ?? ""
        loadProgram(descriptor)
        let embedded = ctFont != nil || type1 != nil
        if !embedded { loadSubstitute(baseFont, descriptor: descriptor) }

        // Encoding: a base table plus Differences.
        var base: [String?]?
        if let name = pdfName(dictionary, "Encoding") {
            base = baseEncodingNames(name)
            hasEncoding = base != nil
        } else if let encoding = pdfDictionary(dictionary, "Encoding") {
            base = baseEncodingNames(pdfName(encoding, "BaseEncoding"))
            if base != nil { hasEncoding = true }
            if let differences = pdfArray(encoding, "Differences") {
                // Without /BaseEncoding the differences apply over the font's own encoding: StandardEncoding for a stand-in font.
                var table = base ?? (embedded || isSymbolFont ? [String?](repeating: nil, count: 256) : standardEncodingNames)
                var code = 0
                for index in 0..<CGPDFArrayGetCount(differences) {
                    var object: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(differences, index, &object), let object else { continue }
                    var integer: CGPDFInteger = 0
                    var name: UnsafePointer<CChar>?
                    if CGPDFObjectGetValue(object, .integer, &integer) { code = integer } else if CGPDFObjectGetValue(object, .name, &name), let name {
                        if code >= 0, code < 256 { table[code] = String(cString: name) }
                        code += 1
                    }
                }
                base = table
                hasEncoding = true
            }
        }
        if !embedded, !isSymbolFont, base == nil { base = standardEncodingNames }
        if let base { names = base }

        let flagsValue = descriptor.flatMap { pdfNumber($0, "Flags") }.map(pdfInt) ?? 0
        symbolicFlag = flagsValue & 4 != 0

        if let table = pdfNumbers(dictionary, "Widths"), let first = pdfNumber(dictionary, "FirstChar") {
            for (index, width) in table.enumerated() { widths[pdfInt(first) + index] = width }
            widthsKnown = true
        }
        defaultWidth = descriptor.flatMap { pdfNumber($0, "MissingWidth") } ?? 0
    }

    private var symbolicFlag = false

    private func loadComposite(_ dictionary: CGPDFDictionaryRef) {
        var descendant: CGPDFDictionaryRef?
        if let array = pdfArray(dictionary, "DescendantFonts") { _ = CGPDFArrayGetDictionary(array, 0, &descendant) }
        let descriptor = descendant.flatMap { pdfDictionary($0, "FontDescriptor") }
        loadProgram(descriptor)
        if ctFont == nil && type1 == nil { loadSubstitute(pdfName(descendant ?? dictionary, "BaseFont") ?? pdfName(dictionary, "BaseFont") ?? "", descriptor: descriptor) }

        if let name = pdfName(dictionary, "Encoding") {
            identityCMap = name.hasPrefix("Identity")
            vertical = name.hasSuffix("-V")
            unicodeCMapName = name.contains("UCS2") || name.contains("UTF16")
            cmapUnknown = !identityCMap && !unicodeCMapName
        } else if let stream = pdfStream(dictionary, "Encoding"), let data = pdfData(stream)?.data {
            var map = ParsedCMap(data)
            if let dictionary = CGPDFStreamGetDictionary(stream) {
                var wmode: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(dictionary, "WMode", &wmode), wmode == 1 { map.vertical = true }
            }
            vertical = map.vertical
            encodingCMap = map
        } else {
            identityCMap = true
        }
        if let stream = pdfStream(dictionary, "ToUnicode"), let data = pdfData(stream)?.data { toUnicode = ParsedCMap(data).unicode }

        guard let descendant else { return }
        defaultWidth = pdfNumber(descendant, "DW") ?? 1000
        if let w = pdfArray(descendant, "W") { readCIDWidths(w) }
        widthsKnown = true
        if let dw2 = pdfNumbers(descendant, "DW2"), dw2.count >= 2 { verticalOrigin = dw2[0]; verticalAdvance = dw2[1] }
        if let stream = pdfStream(descendant, "CIDToGIDMap"), let data = pdfData(stream)?.data { cidToGID = [UInt8](data) }
    }

    private func readCIDWidths(_ array: CGPDFArrayRef) {
        var index = 0
        let count = CGPDFArrayGetCount(array)
        func number(_ i: Int) -> CGFloat? {
            var value: CGPDFReal = 0
            return i < count && CGPDFArrayGetNumber(array, i, &value) ? value : nil
        }
        while index < count {
            guard let first = number(index) else { break }
            var list: CGPDFArrayRef?
            if CGPDFArrayGetArray(array, index + 1, &list), let list {
                for (offset, width) in pdfNumbers(list).enumerated() { widths[pdfInt(first) + offset] = width }
                index += 2
            } else if let last = number(index + 1), let width = number(index + 2), last >= first, last - first < 70_000 {
                for cid in pdfInt(first)...pdfInt(last) { widths[cid] = width }
                index += 3
            } else {
                break
            }
        }
    }

    private func loadType3(_ dictionary: CGPDFDictionaryRef) {
        type3Procs = pdfDictionary(dictionary, "CharProcs")
        type3Matrix = pdfMatrix(pdfNumbers(dictionary, "FontMatrix")) ?? type3Matrix
        type3Resources = pdfDictionary(dictionary, "Resources")
        if let encoding = pdfDictionary(dictionary, "Encoding"), let differences = pdfArray(encoding, "Differences") {
            var code = 0
            for index in 0..<CGPDFArrayGetCount(differences) {
                var object: CGPDFObjectRef?
                guard CGPDFArrayGetObject(differences, index, &object), let object else { continue }
                var integer: CGPDFInteger = 0
                var name: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(object, .integer, &integer) { code = integer } else if CGPDFObjectGetValue(object, .name, &name), let name {
                    if code >= 0, code < 256 { names[code] = String(cString: name) }
                    code += 1
                }
            }
        }
        if let table = pdfNumbers(dictionary, "Widths"), let first = pdfNumber(dictionary, "FirstChar") {
            for (index, width) in table.enumerated() { widths[pdfInt(first) + index] = width }
            widthsKnown = true
        }
    }

    // MARK: Reading text

    /// Splits a string into (code, CID, byte length).
    func decode(_ bytes: [UInt8], _ visit: (UInt32, Int, Int) -> Void) {
        guard kind == .composite else {
            for byte in bytes { visit(UInt32(byte), Int(byte), 1) }
            return
        }
        if let map = encodingCMap, !map.spaces.isEmpty {
            var i = 0
            while i < bytes.count {
                var matched = 0, code: UInt32 = 0, value: UInt32 = 0
                for length in 1...min(4, map.maxLength) where i + length <= bytes.count {
                    value = value << 8 | UInt32(bytes[i + length - 1])
                    if map.spaces.contains(where: { $0.length == length && value >= $0.low && value <= $0.high }) { matched = length; code = value; break }
                }
                if matched == 0 { matched = min(map.spaces[0].length, bytes.count - i); code = bytes[i..<(i + matched)].reduce(0) { $0 << 8 | UInt32($1) } }
                visit(code, map.cid(code) ?? 0, matched)
                i += matched
            }
            return
        }
        var i = 0
        while i < bytes.count {
            let code = i + 1 < bytes.count ? UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]) : UInt32(bytes[i])
            visit(code, Int(code), min(2, bytes.count - i))
            i += 2
        }
    }

    /// Advance in thousandths of the font size.
    func width(code: UInt32, cid: Int) -> CGFloat {
        if kind == .composite { return widths[cid] ?? defaultWidth }
        if widthsKnown { return widths[Int(code)] ?? defaultWidth }
        return substituteAdvance(code)
    }

    private func substituteAdvance(_ code: UInt32) -> CGFloat {
        guard let ctFont, var glyph = simpleGlyph(code) else { return defaultWidth }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        return advance.width * 1000
    }

    private func simpleGlyph(_ code: UInt32) -> CGGlyph? {
        guard let ctFont else { return nil }
        let name = Int(code) < names.count ? names[Int(code)] : nil
        if substitute {
            if isSymbolFont, let glyph = cmaps?.macRoman?[code] ?? cmaps?.symbol?[0xF000 + code] ?? cmaps?.symbol?[code] { return glyph }
            if let name, let scalar = unicodeForGlyphName(name), let glyph = unicodeGlyph(scalar, font: ctFont) { return glyph }
            if let name, let graphics = Optional(CTFontCopyGraphicsFont(ctFont, nil)), case let glyph = graphics.getGlyphWithGlyphName(name: name as CFString), glyph != 0 { return glyph }
            if !hasEncoding, code > 31, let glyph = unicodeGlyph(code, font: ctFont) { return glyph }
            return nil
        }
        let graphics = CTFontCopyGraphicsFont(ctFont, nil)
        if let name {
            if cmaps != nil {
                if let scalar = unicodeForGlyphName(name), let glyph = cmaps?.unicode?[scalar] { return glyph }
                if let mac = macRomanCode(name), let glyph = cmaps?.macRoman?[mac] { return glyph }
            }
            let glyph = graphics.getGlyphWithGlyphName(name: name as CFString)
            if glyph != 0 { return glyph }
        }
        if let cff {
            if let glyph = cff.builtInEncoding[Int(code)] { return glyph }
            if cff.usesStandardEncoding, let standard = standardEncodingNames[safe: Int(code)] ?? nil {
                let glyph = graphics.getGlyphWithGlyphName(name: standard as CFString)
                if glyph != 0 { return glyph }
            }
        }
        if let cmaps {
            if let glyph = cmaps.symbol?[code] ?? cmaps.symbol?[0xF000 + code] ?? cmaps.symbol?[0xF100 + code] ?? cmaps.symbol?[0xF200 + code] { return glyph }
            if let glyph = cmaps.macRoman?[code] { return glyph }
            if let glyph = cmaps.unicode?[code] { return glyph }
        }
        return nil
    }

    private func macRomanCode(_ name: String) -> UInt32? {
        guard let scalar = unicodeForGlyphName(name), let unicode = UnicodeScalar(scalar),
              let data = String(Character(unicode)).data(using: .macOSRoman), data.count == 1 else { return nil }
        return UInt32(data[data.startIndex])
    }

    private func unicodeGlyph(_ scalar: UInt32, font: CTFont) -> CGGlyph? {
        guard let unicode = UnicodeScalar(scalar) else { return nil }
        var units = Array(String(Character(unicode)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    /// Outline in em units (1 = the font size). `known` is false when no glyph could be found for the code.
    func outline(code: UInt32, cid: Int) -> (path: CGPath?, known: Bool) {
        let key = kind == .composite ? cid : Int(code)
        if let cached = outlines[key] { return cached }
        let result = resolveOutline(code: code, cid: cid)
        outlines[key] = result
        return result
    }

    private func resolveOutline(code: UInt32, cid: Int) -> (path: CGPath?, known: Bool) {
        if kind == .composite { return compositeOutline(code: code, cid: cid) }
        if let type1 {
            let explicit = Int(code) < names.count ? names[Int(code)] : nil
            let name = explicit ?? type1.encodedName(Int(code)) ?? (type1.usesStandardEncoding ? (standardEncodingNames[safe: Int(code)] ?? nil) : nil)
            guard let name, type1.hasGlyph(name) else { return (nil, code == 32) }
            return (type1.outline(name), true)
        }
        guard let ctFont else { return (nil, false) }
        guard let glyph = simpleGlyph(code) else { return (nil, code == 32 || (names[safe: Int(code)] ?? nil) == "space") }
        return (CTFontCreatePathForGlyph(ctFont, glyph, nil), true)
    }

    private func compositeOutline(code: UInt32, cid: Int) -> (path: CGPath?, known: Bool) {
        guard let ctFont else { return (nil, false) }
        if substitute {
            var scalar = toUnicode[code]
            if scalar == nil, unicodeCMapName { scalar = code }
            guard let scalar else { return (nil, false) }
            if scalar == 32 || scalar == 0xA0 { return (nil, true) }
            if let glyph = unicodeGlyph(scalar, font: ctFont) { return (CTFontCreatePathForGlyph(ctFont, glyph, nil), true) }
            guard let unicode = UnicodeScalar(scalar) else { return (nil, false) }
            let text = String(Character(unicode))
            let fallback = CTFontCreateForString(ctFont, text as CFString, CFRange(location: 0, length: (text as NSString).length))
            guard let glyph = unicodeGlyph(scalar, font: fallback) else { return (nil, false) }
            return (CTFontCreatePathForGlyph(fallback, glyph, nil), true)
        }
        if cmapUnknown { return (nil, false) }
        var glyph: CGGlyph
        if let cff, cff.isCID {
            guard let mapped = cff.cidToGlyph[cid] else { return (nil, cid == 0) }
            glyph = mapped
        } else if let cidToGID {
            guard cid * 2 + 1 < cidToGID.count else { return (nil, false) }
            glyph = CGGlyph(cidToGID[cid * 2]) << 8 | CGGlyph(cidToGID[cid * 2 + 1])
        } else {
            glyph = CGGlyph(truncatingIfNeeded: cid)
        }
        if Int(glyph) >= CTFontGetGlyphCount(ctFont) { glyph = 0 }
        return (CTFontCreatePathForGlyph(ctFont, glyph, nil), true)
    }
}

// MARK: - Interpreter

fileprivate struct GraphicsState {
    var ctm: CGAffineTransform
    var fill: Paint = .color(.black)
    var stroke: Paint = .color(.black)
    var fillSpace: ColorModel = .gray
    var strokeSpace: ColorModel = .gray
    var fillAlpha: CGFloat = 1
    var strokeAlpha: CGFloat = 1
    var lineWidth: CGFloat = 1
    var lineCap = 0
    var lineJoin = 0
    var miter: CGFloat = 10
    var dash: [CGFloat] = []
    var dashPhase: CGFloat = 0
    var blend: String?
    var softMask = false
    var wrappers: [SVGWrapper] = []
    var clipBox: CGRect

    var font: SVGFont?
    var fontSize: CGFloat = 0
    var charSpace: CGFloat = 0
    var wordSpace: CGFloat = 0
    var horizontalScale: CGFloat = 1
    var leading: CGFloat = 0
    var rise: CGFloat = 0
    var renderMode = 0
}

/// An open `<g>`: a clip or a transparency group.
fileprivate struct SVGWrapper: Equatable {
    var id: String
    var attributes: String
}

final class PDFSVGInterpreter {
    private static let maxDepth = 24
    private static let maxBodyBytes = 209_715_200
    private static let maxPatches = 512
    private static let maxOperators = 50_000_000

    fileprivate let page: PDFPage
    fileprivate let cgPage: CGPDFPage
    fileprivate let geometry: PageGeometry
    fileprivate let pageRect: CGRect

    private var body = ""
    private var defs = ""
    private var openWrappers: [SVGWrapper] = []
    private var clipIDs: [String: String] = [:]
    private var nextID = 0

    private var gs: GraphicsState
    private var stack: [GraphicsState] = []
    private var stackFloor = 0

    private var path = CGMutablePath()
    private var pathPoint: CGPoint?
    private var subpathStart: CGPoint?
    private var pendingClip: Bool?

    private var textMatrix = CGAffineTransform.identity
    private var textLineMatrix = CGAffineTransform.identity
    private var textClip: CGMutablePath?

    private var content: CGPDFContentStreamRef?
    private var depth = 0
    private var activeForms = Set<UnsafeRawPointer>()
    private var fonts: [UnsafeRawPointer: SVGFont] = [:]
    private var imageCache: [String: (href: String, width: Int, height: Int)] = [:]

    private var markedContent: [Bool] = []
    private var hiddenLayers = 0
    private var colorLocked = false

    private var operators = 0
    private var patches = 0
    private var pageImage: CGImage?
    private var pageImageScale: CGFloat = 1
    private var deadline = Date(timeIntervalSinceNow: 90)
    private var unsupported = false

    private lazy var hiddenGroups: (off: Set<UnsafeRawPointer>, on: Set<UnsafeRawPointer>, baseOff: Bool) = readOptionalContent()

    fileprivate init?(page: PDFPage, geometry: PageGeometry) {
        guard let cgPage = page.pageRef else { return nil }
        self.page = page
        self.cgPage = cgPage
        self.geometry = geometry
        pageRect = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        gs = GraphicsState(ctm: geometry.base, clipBox: pageRect)
    }

    /// The finished SVG, or nil when the page has to fall back to one image.
    func render() -> String? {
        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        content = stream
        scan(stream)
        drawAnnotations()
        content = nil
        CGPDFContentStreamRelease(stream)
        guard !unsupported else { return nil }
        closeWrappers(keeping: 0)
        var out = PDFToSVG.header(geometry)
        if !defs.isEmpty { out += "<defs>" + defs + "</defs>" }
        out += body + "</svg>"
        return out
    }

    private func scan(_ stream: CGPDFContentStreamRef) {
        let info = Unmanaged.passUnretained(self).toOpaque()
        let scanner = CGPDFScannerCreate(stream, Self.operatorTable, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private func tick() -> Bool {
        if unsupported { return false }
        operators += 1
        if operators > Self.maxOperators || (operators & 0xFFF == 0 && Date() > deadline) { unsupported = true }
        return !unsupported
    }

    // MARK: Output

    private func newID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    private func closeWrappers(keeping count: Int) {
        while openWrappers.count > count {
            body += "</g>"
            openWrappers.removeLast()
        }
    }

    private func syncWrappers() {
        var shared = 0
        while shared < openWrappers.count, shared < gs.wrappers.count, openWrappers[shared] == gs.wrappers[shared] { shared += 1 }
        closeWrappers(keeping: shared)
        for wrapper in gs.wrappers[shared...] {
            body += "<g \(wrapper.attributes)>"
            openWrappers.append(wrapper)
        }
    }

    private func emit(_ element: String) {
        syncWrappers()
        body += element
        if body.utf8.count > Self.maxBodyBytes { unsupported = true }
    }

    private var isHidden: Bool { hiddenLayers > 0 }

    private func serialize(_ path: CGPath, transform: CGAffineTransform? = nil, places: Int = 3) -> String {
        var out = ""
        out.reserveCapacity(64)
        func point(_ p: CGPoint) {
            let q = transform.map { p.applying($0) } ?? p
            out += svgNumber(q.x, places: places)
            out += " "
            out += svgNumber(q.y, places: places)
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: out += "M"; point(e.points[0])
            case .addLineToPoint: out += "L"; point(e.points[0])
            case .addQuadCurveToPoint: out += "Q"; point(e.points[0]); out += " "; point(e.points[1])
            case .addCurveToPoint: out += "C"; point(e.points[0]); out += " "; point(e.points[1]); out += " "; point(e.points[2])
            case .closeSubpath: out += "Z"
            @unknown default: break
            }
        }
        return out
    }

    private func blendAttribute() -> String { gs.blend.map { " style=\"mix-blend-mode:\($0)\"" } ?? "" }

    private func fillAttributes(_ color: SVGColor, evenOdd: Bool) -> String {
        var out = " fill=\"\(color.hex)\""
        if evenOdd { out += " fill-rule=\"evenodd\"" }
        if gs.fillAlpha < 1 { out += " fill-opacity=\"\(svgNumber(gs.fillAlpha))\"" }
        return out
    }

    private func strokeAttributes(_ color: SVGColor, scale: CGFloat) -> String {
        let width = gs.lineWidth > 0 ? gs.lineWidth * scale : 0.5
        var out = " stroke=\"\(color.hex)\" stroke-width=\"\(svgNumber(width, places: 4))\""
        if gs.strokeAlpha < 1 { out += " stroke-opacity=\"\(svgNumber(gs.strokeAlpha))\"" }
        if gs.lineCap == 1 { out += " stroke-linecap=\"round\"" } else if gs.lineCap == 2 { out += " stroke-linecap=\"square\"" }
        if gs.lineJoin == 1 { out += " stroke-linejoin=\"round\"" } else if gs.lineJoin == 2 { out += " stroke-linejoin=\"bevel\"" }
        out += " stroke-miterlimit=\"\(svgNumber(gs.miter))\""
        if !gs.dash.isEmpty, gs.dash.allSatisfy({ $0 >= 0 }), gs.dash.contains(where: { $0 > 0 }) {
            out += " stroke-dasharray=\"" + gs.dash.map { svgNumber($0 * scale, places: 4) }.joined(separator: " ") + "\""
            if gs.dashPhase != 0 { out += " stroke-dashoffset=\"\(svgNumber(gs.dashPhase * scale, places: 4))\"" }
        }
        return out
    }

    /// The CTM's uniform scale, or nil when strokes have to be written in user space.
    private func similarityScale(_ m: CGAffineTransform) -> CGFloat? {
        let sx = hypot(m.a, m.b), sy = hypot(m.c, m.d)
        guard sx > 0, sy > 0, abs(m.a * m.c + m.b * m.d) <= 1e-4 * sx * sy, abs(sx - sy) <= 1e-3 * max(sx, sy) else { return nil }
        return sx
    }

    // MARK: Patches

    /// Covers a region with the page's own rendering, for marks SVG can't express. Later marks are drawn over it again.
    private func patch(bounds: CGRect, clip region: CGPath? = nil, evenOdd: Bool = false) {
        guard !isHidden, !unsupported else { return }
        let visible = bounds.intersection(gs.clipBox).intersection(pageRect)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        patches += 1
        guard patches <= Self.maxPatches else { unsupported = true; return }
        if pageImage == nil {
            pageImageScale = PDFToSVG.rasterScale(geometry)
            pageImage = PDFToSVG.pageBitmap(page, geometry: geometry, scale: pageImageScale, white: false)
        }
        guard let image = pageImage else { unsupported = true; return }
        let left = (visible.minX * pageImageScale).rounded(.down), top = (visible.minY * pageImageScale).rounded(.down)
        let right = (visible.maxX * pageImageScale).rounded(.up), bottom = (visible.maxY * pageImageScale).rounded(.up)
        guard let crop = image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)), let png = pngData(crop) else { return }
        let saved = gs.wrappers
        if let region { pushClip(region, evenOdd: evenOdd, updateBox: false) }
        let x = left / pageImageScale, y = top / pageImageScale
        let w = (right - left) / pageImageScale, h = (bottom - top) / pageImageScale
        emit("<image x=\"\(svgNumber(x))\" y=\"\(svgNumber(y))\" width=\"\(svgNumber(w))\" height=\"\(svgNumber(h))\" preserveAspectRatio=\"none\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>")
        gs.wrappers = saved
    }

    // MARK: Clipping

    private func pushClip(_ device: CGPath, evenOdd: Bool, updateBox: Bool = true) {
        guard !device.isEmpty else { return }
        let box = device.boundingBoxOfPath
        if updateBox { gs.clipBox = gs.clipBox.intersection(box) }
        var rect = CGRect.zero
        if device.isRect(&rect), rect.contains(pageRect) { return }
        let d = serialize(device)
        let key = d + (evenOdd ? "e" : "n")
        let id: String
        if let known = clipIDs[key] { id = known } else {
            id = newID("c")
            clipIDs[key] = id
            defs += "<clipPath id=\"\(id)\"><path d=\"\(d)\"\(evenOdd ? " clip-rule=\"evenodd\"" : "")/></clipPath>"
        }
        if gs.wrappers.last?.id != id { gs.wrappers.append(SVGWrapper(id: id, attributes: "clip-path=\"url(#\(id))\"")) }
    }

    // MARK: Paths

    private func resetPath() {
        path = CGMutablePath()
        pathPoint = nil
        subpathStart = nil
    }

    private func move(_ p: CGPoint) {
        let device = p.applying(gs.ctm)
        path.move(to: device)
        pathPoint = device
        subpathStart = device
    }

    private func line(_ p: CGPoint) {
        guard pathPoint != nil else { move(p); return }
        let device = p.applying(gs.ctm)
        path.addLine(to: device)
        pathPoint = device
    }

    private func curve(_ c1: CGPoint?, _ c2: CGPoint?, _ end: CGPoint) {
        guard pathPoint != nil else { move(end); return }
        let deviceEnd = end.applying(gs.ctm)
        let first = c1?.applying(gs.ctm) ?? pathPoint!
        let second = c2?.applying(gs.ctm) ?? deviceEnd
        path.addCurve(to: deviceEnd, control1: first, control2: second)
        pathPoint = deviceEnd
    }

    private func closePath() {
        guard pathPoint != nil, !path.isEmpty else { return }
        path.closeSubpath()
        pathPoint = subpathStart
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        move(CGPoint(x: x, y: y))
        line(CGPoint(x: x + w, y: y))
        line(CGPoint(x: x + w, y: y + h))
        line(CGPoint(x: x, y: y + h))
        closePath()
    }

    private func paintPath(fill: Bool, stroke: Bool, evenOdd: Bool = false) {
        defer {
            if let rule = pendingClip { pushClip(path, evenOdd: rule) }
            pendingClip = nil
            resetPath()
        }
        guard !path.isEmpty, !isHidden else { return }
        drawShape(path, fill: fill, stroke: stroke, evenOdd: evenOdd)
    }

    /// Draws a device-space outline with the current paints, patching whatever SVG can't express.
    private func drawShape(_ shape: CGPath, fill: Bool, stroke: Bool, evenOdd: Bool) {
        var fillColor: SVGColor?
        var strokeColor: SVGColor?
        if fill {
            switch gs.fill {
            case .color(let color) where !gs.softMask: fillColor = color
            case .none: break
            default: patch(bounds: shape.boundingBoxOfPath, clip: shape, evenOdd: evenOdd)
            }
        }
        if stroke {
            switch gs.stroke {
            case .color(let color) where !gs.softMask: strokeColor = color
            case .none: break
            default:
                let reach = max(gs.lineWidth, 0.5) * max(hypot(gs.ctm.a, gs.ctm.b), hypot(gs.ctm.c, gs.ctm.d)) * max(gs.miter / 2, 1)
                patch(bounds: shape.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach))
            }
        }
        guard fillColor != nil || strokeColor != nil else { return }
        var attributes = fillColor.map { fillAttributes($0, evenOdd: evenOdd) } ?? " fill=\"none\""
        var transform: CGAffineTransform?
        var inverse: CGAffineTransform?
        var scale: CGFloat = 1
        if let strokeColor {
            if let uniform = similarityScale(gs.ctm) {
                scale = uniform
            } else {
                let determinant = gs.ctm.a * gs.ctm.d - gs.ctm.b * gs.ctm.c
                guard abs(determinant) > 1e-12, determinant.isFinite else {
                    if fillColor != nil { emit("<path d=\"\(serialize(shape))\"\(attributes)\(blendAttribute())/>") }
                    return
                }
                transform = gs.ctm
                inverse = gs.ctm.inverted()
            }
            attributes += strokeAttributes(strokeColor, scale: scale)
        }
        var head = "<path"
        if let transform { head += " transform=\"matrix(\(matrixText(transform)))\"" }
        emit("\(head) d=\"\(serialize(shape, transform: inverse, places: inverse == nil ? 3 : 6))\"\(attributes)\(blendAttribute())/>")
    }

    private func matrixText(_ m: CGAffineTransform) -> String {
        [m.a, m.b, m.c, m.d, m.tx, m.ty].map { svgNumber($0, places: 6) }.joined(separator: " ")
    }

    // MARK: Colour

    private func colorSpace(_ object: CGPDFObjectRef?, depth: Int = 0) -> ColorModel? {
        guard let object, depth < 8 else { return nil }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name { return colorSpace(named: String(cString: name), depth: depth) }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) > 0 else { return nil }
        var head: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &head), let head else { return nil }
        func entry(_ index: Int) -> CGPDFObjectRef? {
            var value: CGPDFObjectRef?
            return CGPDFArrayGetObject(array, index, &value) ? value : nil
        }
        switch String(cString: head) {
        case "ICCBased":
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
            var count: CGPDFInteger = 0
            _ = CGPDFDictionaryGetInteger(dictionary, "N", &count)
            if let raw = pdfData(stream)?.data, let space = CGColorSpace(iccData: raw as CFData), space.numberOfComponents == count { return .icc(space, count) }
            switch count {
            case 1: return .gray
            case 3: return .rgb
            case 4: return .cmyk
            default: return nil
            }
        case "CalGray":
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, 1, &dictionary), let dictionary, let white = pdfNumbers(dictionary, "WhitePoint"), white.count >= 3 else { return .gray }
            let black = pdfNumbers(dictionary, "BlackPoint") ?? [0, 0, 0]
            guard black.count >= 3 else { return .gray }
            return CGColorSpace(calibratedGrayWhitePoint: white, blackPoint: black, gamma: pdfNumber(dictionary, "Gamma") ?? 1).map { .icc($0, 1) } ?? .gray
        case "CalRGB":
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, 1, &dictionary), let dictionary, let white = pdfNumbers(dictionary, "WhitePoint"), white.count >= 3 else { return .rgb }
            let black = pdfNumbers(dictionary, "BlackPoint") ?? [0, 0, 0]
            let gamma = pdfNumbers(dictionary, "Gamma") ?? [1, 1, 1]
            let matrix = pdfNumbers(dictionary, "Matrix") ?? [1, 0, 0, 0, 1, 0, 0, 0, 1]
            guard black.count >= 3, gamma.count >= 3, matrix.count >= 9 else { return .rgb }
            return CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: black, gamma: gamma, matrix: matrix).map { .icc($0, 3) } ?? .rgb
        case "Lab":
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, 1, &dictionary), let dictionary, let white = pdfNumbers(dictionary, "WhitePoint"), white.count >= 3 else { return nil }
            let black = pdfNumbers(dictionary, "BlackPoint") ?? [0, 0, 0]
            let range = pdfNumbers(dictionary, "Range") ?? [-100, 100, -100, 100]
            guard black.count >= 3, range.count >= 4 else { return nil }
            return white.withUnsafeBufferPointer { w in black.withUnsafeBufferPointer { b in range.withUnsafeBufferPointer { r in
                CGColorSpace(labWhitePoint: w.baseAddress!, blackPoint: b.baseAddress!, range: r.baseAddress!).map { ColorModel.lab($0) }
            } } }
        case "Indexed", "I":
            guard let base = colorSpace(entry(1), depth: depth + 1) else { return nil }
            var high: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(array, 2, &high), high >= 0, high <= 255 else { return nil }
            var table: [UInt8] = []
            var string: CGPDFStringRef?
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetString(array, 3, &string), let string { table = pdfBytes(string) } else if CGPDFArrayGetStream(array, 3, &stream), let stream, let raw = pdfData(stream)?.data { table = [UInt8](raw) }
            return .indexed(base, high, table)
        case "Separation":
            guard let alternate = colorSpace(entry(2), depth: depth + 1) else { return nil }
            var colorant: UnsafePointer<CChar>?
            let isNone = CGPDFArrayGetName(array, 1, &colorant) && colorant.map { String(cString: $0) == "None" } == true
            return .tint(1, alternate, entry(3).flatMap { PDFTintFunction($0) }, isNone: isNone)
        case "DeviceN":
            var names: CGPDFArrayRef?
            guard CGPDFArrayGetArray(array, 1, &names), let names, let alternate = colorSpace(entry(2), depth: depth + 1) else { return nil }
            return .tint(CGPDFArrayGetCount(names), alternate, entry(3).flatMap { PDFTintFunction($0) }, isNone: false)
        case "Pattern":
            return .pattern(colorSpace(entry(1), depth: depth + 1))
        default:
            return colorSpace(named: String(cString: head), depth: depth)
        }
    }

    private func colorSpace(named name: String, depth: Int) -> ColorModel? {
        switch name {
        case "DeviceGray", "G", "CalGray": return .gray
        case "DeviceRGB", "RGB", "CalRGB": return .rgb
        case "DeviceCMYK", "CMYK": return .cmyk
        case "Pattern": return .pattern(nil)
        default:
            guard let content, let object = CGPDFContentStreamGetResource(content, "ColorSpace", name) else { return nil }
            return colorSpace(object, depth: depth + 1)
        }
    }

    private func setSpace(_ name: String, stroke: Bool) {
        guard !colorLocked else { return }
        let model = colorSpace(named: name, depth: 0) ?? .gray
        let paint = model.paint(model.initialComponents)
        if stroke { gs.strokeSpace = model; gs.stroke = paint } else { gs.fillSpace = model; gs.fill = paint }
    }

    private func setColor(_ model: ColorModel, _ components: [CGFloat], stroke: Bool) {
        guard !colorLocked else { return }
        let paint = model.paint(components)
        if stroke { gs.strokeSpace = model; gs.stroke = paint } else { gs.fillSpace = model; gs.fill = paint }
    }

    private func setColorFromOperands(_ scanner: CGPDFScannerRef, stroke: Bool) {
        var values: [CGFloat] = []
        var pattern = false
        var object: CGPDFObjectRef?
        while CGPDFScannerPopObject(scanner, &object), let item = object {
            var number: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(item, .real, &number) { values.append(number) } else if CGPDFObjectGetValue(item, .name, &name) { pattern = true }
        }
        guard !colorLocked else { return }
        let model = stroke ? gs.strokeSpace : gs.fillSpace
        if pattern {
            if stroke { gs.stroke = .pattern } else { gs.fill = .pattern }
            return
        }
        let paint = model.paint(values.reversed())
        if stroke { gs.stroke = paint } else { gs.fill = paint }
    }

    // MARK: ExtGState

    private func applyExtGState(_ name: String) {
        guard let content, let object = CGPDFContentStreamGetResource(content, "ExtGState", name) else { return }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let d = dictionary else { return }
        if let value = pdfNumber(d, "ca") { gs.fillAlpha = min(max(value, 0), 1) }
        if let value = pdfNumber(d, "CA") { gs.strokeAlpha = min(max(value, 0), 1) }
        if let value = pdfNumber(d, "LW") { gs.lineWidth = value }
        if let value = pdfNumber(d, "ML") { gs.miter = value }
        if let value = pdfNumber(d, "LC") { gs.lineCap = pdfInt(value) }
        if let value = pdfNumber(d, "LJ") { gs.lineJoin = pdfInt(value) }
        if let dash = pdfArray(d, "D") {
            var inner: CGPDFArrayRef?
            var phase: CGPDFReal = 0
            if CGPDFArrayGetArray(dash, 0, &inner), let inner, CGPDFArrayGetNumber(dash, 1, &phase) {
                gs.dash = pdfNumbers(inner)
                gs.dashPhase = phase
            }
        }
        if let blendName = pdfName(d, "BM") {
            gs.blend = Self.blendMode(blendName)
        } else if let list = pdfArray(d, "BM") {
            for index in 0..<CGPDFArrayGetCount(list) {
                var value: UnsafePointer<CChar>?
                if CGPDFArrayGetName(list, index, &value), let value {
                    gs.blend = Self.blendMode(String(cString: value))
                    break
                }
            }
        }
        var object2: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(d, "SMask", &object2), let object2 {
            var mask: UnsafePointer<CChar>?
            gs.softMask = !(CGPDFObjectGetValue(object2, .name, &mask) && mask.map { String(cString: $0) == "None" } == true)
        }
        if let fontEntry = pdfArray(d, "Font") {
            var fontDictionary: CGPDFDictionaryRef?
            var size: CGPDFReal = 0
            if CGPDFArrayGetDictionary(fontEntry, 0, &fontDictionary), let fontDictionary, CGPDFArrayGetNumber(fontEntry, 1, &size) {
                gs.font = font(for: fontDictionary)
                gs.fontSize = size
            }
        }
    }

    private static func blendMode(_ name: String) -> String? {
        switch name {
        case "Multiply": return "multiply"
        case "Screen": return "screen"
        case "Overlay": return "overlay"
        case "Darken": return "darken"
        case "Lighten": return "lighten"
        case "ColorDodge": return "color-dodge"
        case "ColorBurn": return "color-burn"
        case "HardLight": return "hard-light"
        case "SoftLight": return "soft-light"
        case "Difference": return "difference"
        case "Exclusion": return "exclusion"
        case "Hue": return "hue"
        case "Saturation": return "saturation"
        case "Color": return "color"
        case "Luminosity": return "luminosity"
        default: return nil
        }
    }

    // MARK: Optional content

    private func readOptionalContent() -> (off: Set<UnsafeRawPointer>, on: Set<UnsafeRawPointer>, baseOff: Bool) {
        var result: (off: Set<UnsafeRawPointer>, on: Set<UnsafeRawPointer>, baseOff: Bool) = ([], [], false)
        guard let catalog = cgPage.document?.catalog, let properties = pdfDictionary(catalog, "OCProperties"), let d = pdfDictionary(properties, "D") else { return result }
        result.baseOff = pdfName(d, "BaseState") == "OFF"
        func read(_ key: String) -> Set<UnsafeRawPointer> {
            guard let array = pdfArray(d, key) else { return [] }
            var out = Set<UnsafeRawPointer>()
            for index in 0..<CGPDFArrayGetCount(array) {
                var group: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(array, index, &group), let group { out.insert(objectKey(group)) }
            }
            return out
        }
        result.off = read("OFF")
        result.on = read("ON")
        return result
    }

    private func isVisible(group: CGPDFDictionaryRef) -> Bool {
        let key = objectKey(group)
        let state = hiddenGroups
        if state.off.contains(key) { return false }
        if state.on.contains(key) { return true }
        return !state.baseOff
    }

    private func isVisible(optionalContent dictionary: CGPDFDictionaryRef) -> Bool {
        guard pdfName(dictionary, "Type") == "OCMD" else { return isVisible(group: dictionary) }
        var groups: [CGPDFDictionaryRef] = []
        if let single = pdfDictionary(dictionary, "OCGs") { groups = [single] } else if let list = pdfArray(dictionary, "OCGs") {
            for index in 0..<CGPDFArrayGetCount(list) {
                var group: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(list, index, &group), let group { groups.append(group) }
            }
        }
        guard !groups.isEmpty else { return true }
        let visible = groups.map { isVisible(group: $0) }
        switch pdfName(dictionary, "P") ?? "AnyOn" {
        case "AllOn": return visible.allSatisfy { $0 }
        case "AnyOff": return visible.contains(false)
        case "AllOff": return !visible.contains(true)
        default: return visible.contains(true)
        }
    }

    private func beginMarkedContent(tag: String, properties: CGPDFDictionaryRef?) {
        var hidden = false
        if tag == "OC", let properties, !isVisible(optionalContent: properties) { hidden = true }
        markedContent.append(hidden)
        if hidden { hiddenLayers += 1 }
    }

    private func endMarkedContent() {
        if markedContent.popLast() == true { hiddenLayers -= 1 }
    }

    // MARK: XObjects

    private func drawXObject(_ name: String) {
        guard let content, let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        if let oc = pdfDictionary(dictionary, "OC"), !isVisible(optionalContent: oc) { return }
        guard !isHidden else { return }
        switch pdfName(dictionary, "Subtype") {
        case "Form": drawForm(stream, dictionary: dictionary)
        case "Image": drawImage(stream, dictionary: dictionary)
        default: break
        }
    }

    private func drawForm(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef) {
        let key = objectKey(stream)
        guard depth < Self.maxDepth, !activeForms.contains(key) else {
            if let box = pdfNumbers(dictionary, "BBox"), box.count >= 4 { patch(bounds: formBounds(box, matrix: pdfMatrix(pdfNumbers(dictionary, "Matrix")))) }
            return
        }
        let matrix = pdfMatrix(pdfNumbers(dictionary, "Matrix"))
        let box = pdfNumbers(dictionary, "BBox")
        if gs.softMask {
            if let box, box.count >= 4 { patch(bounds: formBounds(box, matrix: matrix)) }
            return
        }
        let savedState = gs, savedStack = stack, savedFloor = stackFloor, savedContent = content
        let savedPath = path, savedPoint = pathPoint, savedStart = subpathStart, savedPending = pendingClip
        let savedTextMatrix = textMatrix, savedLine = textLineMatrix, savedClip = textClip
        let savedMarks = markedContent, savedHidden = hiddenLayers
        defer {
            gs = savedState; stack = savedStack; stackFloor = savedFloor; content = savedContent
            path = savedPath; pathPoint = savedPoint; subpathStart = savedStart; pendingClip = savedPending
            textMatrix = savedTextMatrix; textLineMatrix = savedLine; textClip = savedClip
            markedContent = savedMarks; hiddenLayers = savedHidden
            depth -= 1
            activeForms.remove(key)
        }
        depth += 1
        activeForms.insert(key)
        stackFloor = stack.count
        resetPath()
        if let matrix { gs.ctm = matrix.concatenating(gs.ctm) }
        if let box, box.count >= 4 {
            let rectangle = CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1]).standardized
            let clip = CGMutablePath()
            clip.addPath(CGPath(rect: rectangle, transform: nil), transform: gs.ctm)
            pushClip(clip, evenOdd: false)
        }
        if pdfDictionary(dictionary, "Group") != nil, gs.fillAlpha < 1 || gs.blend != nil {
            var attributes = ""
            if gs.fillAlpha < 1 { attributes += "opacity=\"\(svgNumber(gs.fillAlpha))\"" }
            if let blend = gs.blend { attributes += (attributes.isEmpty ? "" : " ") + "style=\"mix-blend-mode:\(blend)\"" }
            gs.wrappers.append(SVGWrapper(id: newID("g"), attributes: attributes))
            gs.fillAlpha = 1; gs.strokeAlpha = 1; gs.blend = nil
        }
        let resources = pdfDictionary(dictionary, "Resources") ?? dictionary
        guard let parent = savedContent else { return }
        let formStream = CGPDFContentStreamCreateWithStream(stream, resources, parent)
        content = formStream
        scan(formStream)
        CGPDFContentStreamRelease(formStream)
    }

    private func formBounds(_ box: [CGFloat], matrix: CGAffineTransform?) -> CGRect {
        let rectangle = CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1]).standardized
        return rectangle.applying((matrix ?? .identity).concatenating(gs.ctm))
    }

    // MARK: Images

    private func imageQuad() -> CGPath {
        var matrix = gs.ctm
        return CGPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1), transform: &matrix)
    }

    /// Inline images skip the cache: their transient streams reuse one address, so the key would not tell them apart.
    private func drawImage(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, inline: Bool = false) {
        guard !isHidden else { return }
        let quad = imageQuad()
        guard !gs.softMask else { patch(bounds: quad.boundingBoxOfPath, clip: quad); return }
        let stencil = pdfBool(dictionary, "ImageMask") ?? pdfBool(dictionary, "IM") ?? false
        var cacheKey = "\(UInt(bitPattern: objectKey(stream)))"
        if stencil {
            guard case .color(let color) = gs.fill else {
                if gs.fill != .none { patch(bounds: quad.boundingBoxOfPath, clip: quad) }
                return
            }
            cacheKey += color.hex
        }
        let encoded: (href: String, width: Int, height: Int)
        if !inline, let cached = imageCache[cacheKey] { encoded = cached } else {
            guard let fresh = encodeImage(stream, dictionary: dictionary, stencil: stencil) else {
                patch(bounds: quad.boundingBoxOfPath, clip: quad)
                return
            }
            if !inline { imageCache[cacheKey] = fresh }
            encoded = fresh
        }
        let place = CGAffineTransform(a: 1 / CGFloat(encoded.width), b: 0, c: 0, d: -1 / CGFloat(encoded.height), tx: 0, ty: 1).concatenating(gs.ctm)
        var attributes = gs.fillAlpha < 1 ? " opacity=\"\(svgNumber(gs.fillAlpha))\"" : ""
        attributes += blendAttribute()
        emit("<image transform=\"matrix(\(matrixText(place)))\" width=\"\(encoded.width)\" height=\"\(encoded.height)\" preserveAspectRatio=\"none\"\(attributes) xlink:href=\"\(encoded.href)\"/>")
    }

    private func imageInt(_ dictionary: CGPDFDictionaryRef, _ long: String, _ short: String) -> Int? {
        var value: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dictionary, long, &value) || CGPDFDictionaryGetInteger(dictionary, short, &value) { return value }
        return nil
    }

    private func encodeImage(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, stencil: Bool) -> (href: String, width: Int, height: Int)? {
        guard let width = imageInt(dictionary, "Width", "W"), let height = imageInt(dictionary, "Height", "H"),
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 60_000_000 else { return nil }
        let decode = pdfNumbers(dictionary, "Decode") ?? pdfNumbers(dictionary, "D")
        if stencil {
            guard let raw = pdfData(stream), raw.format == .raw, case .color(let color) = gs.fill else { return nil }
            guard let image = stencilImage(raw.data, width: width, height: height, invert: decode?.first == 1, color: color) else { return nil }
            return encoded(image, width: width, height: height)
        }
        guard let data = pdfData(stream) else { return nil }

        var object: CGPDFObjectRef?
        var model: ColorModel?
        if CGPDFDictionaryGetObject(dictionary, "ColorSpace", &object) || CGPDFDictionaryGetObject(dictionary, "CS", &object) { model = colorSpace(object) }
        let hasMask = hasKey(dictionary, "SMask") || hasKey(dictionary, "Mask")
        let bits = imageInt(dictionary, "BitsPerComponent", "BPC") ?? 8
        let defaultDecode = decode == nil || isDefaultDecode(decode!, model: model, bits: bits)

        var base: CGImage?
        switch data.format {
        case .jpegEncoded:
            guard let source = CGImageSourceCreateWithData(data.data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let components = image.colorSpace?.numberOfComponents ?? 0
            guard defaultDecode, components == 1 || components == 3 else { return nil }
            if !hasMask, orientation == 1, model?.isDeviceLikeForJPEG != false {
                return ("data:image/jpeg;base64," + data.data.base64EncodedString(), image.width, image.height)
            }
            base = image
        case .JPEG2000:
            guard defaultDecode, let source = CGImageSourceCreateWithData(data.data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            base = image
        default:
            guard let model else { return nil }
            base = sampledImage(data.data, width: width, height: height, bits: bits, model: model, decode: defaultDecode ? nil : decode)
        }
        guard var image = base else { return nil }

        var mask: [UInt8]?
        var outWidth = image.width, outHeight = image.height
        if let smask = pdfStream(dictionary, "SMask"), let maskDictionary = CGPDFStreamGetDictionary(smask), let (values, mw, mh) = softMaskValues(smask, dictionary: maskDictionary) {
            outWidth = max(outWidth, mw); outHeight = max(outHeight, mh)
            guard outWidth * outHeight <= 60_000_000 else { return nil }
            mask = resample(values, width: mw, height: mh, toWidth: outWidth, toHeight: outHeight)
        } else if let explicit = pdfStream(dictionary, "Mask"), let maskDictionary = CGPDFStreamGetDictionary(explicit), let (values, mw, mh) = explicitMaskValues(explicit, dictionary: maskDictionary) {
            outWidth = max(outWidth, mw); outHeight = max(outHeight, mh)
            guard outWidth * outHeight <= 60_000_000 else { return nil }
            mask = resample(values, width: mw, height: mh, toWidth: outWidth, toHeight: outHeight)
        } else if let ranges = pdfArray(dictionary, "Mask") {
            let values = pdfNumbers(ranges)
            guard let keyed = image.copy(maskingColorComponents: values) else { return nil }
            image = keyed
        } else if hasMask {
            return nil
        }
        guard let finished = flatten(image, mask: mask, width: outWidth, height: outHeight) else { return nil }
        return encoded(finished, width: outWidth, height: outHeight)
    }

    private func hasKey(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &object)
    }

    private func isDefaultDecode(_ decode: [CGFloat], model: ColorModel?, bits: Int) -> Bool {
        if case .indexed = model { return decode.count >= 2 && decode[0] == 0 && decode[1] == CGFloat((1 << bits) - 1) }
        return stride(from: 0, to: decode.count - 1, by: 2).allSatisfy { decode[$0] == 0 && decode[$0 + 1] == 1 }
    }

    private func encoded(_ image: CGImage, width: Int, height: Int) -> (href: String, width: Int, height: Int)? {
        guard let png = pngData(image) else { return nil }
        return ("data:image/png;base64," + png.base64EncodedString(), width, height)
    }

    private func sampledImage(_ raw: Data, width: Int, height: Int, bits: Int, model: ColorModel, decode: [CGFloat]?) -> CGImage? {
        guard [1, 2, 4, 8, 16].contains(bits), let space = model.imageSpace else { return nil }
        let components = model.componentCount
        guard components > 0 else { return nil }
        let rowBytes = (width * components * bits + 7) / 8
        guard raw.count >= rowBytes * height, let provider = CGDataProvider(data: raw as CFData) else { return nil }
        // Quartz's Decode semantics for indexed samples differ from PDF's; such an image becomes a patch.
        if case .indexed = model, decode != nil { return nil }
        return decode.withOptionalBuffer { pointer in
            CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: components * bits, bytesPerRow: rowBytes, space: space,
                    bitmapInfo: bits == 16 ? CGBitmapInfo(rawValue: CGImageByteOrderInfo.order16Big.rawValue) : CGBitmapInfo(), provider: provider,
                    decode: pointer, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    private func stencilImage(_ raw: Data, width: Int, height: Int, invert: Bool, color: SVGColor) -> CGImage? {
        let rowBytes = (width + 7) / 8
        guard raw.count >= rowBytes * height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        raw.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for y in 0..<height {
                let row = y * rowBytes
                for x in 0..<width {
                    let bit = (buffer[row + x / 8] >> UInt8(7 - x % 8)) & 1
                    guard (bit == 0) != invert else { continue }
                    let offset = (y * width + x) * 4
                    pixels[offset] = color.r; pixels[offset + 1] = color.g; pixels[offset + 2] = color.b; pixels[offset + 3] = 255
                }
            }
        }
        return rgbaImage(&pixels, width: width, height: height)
    }

    /// Straight-to-premultiplied RGBA bytes; the fill colour above is opaque, so nothing needs scaling here.
    private func rgbaImage(_ pixels: inout [UInt8], width: Int, height: Int) -> CGImage? {
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private func softMaskValues(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef) -> ([UInt8], Int, Int)? {
        guard let data = pdfData(stream) else { return nil }
        var image: CGImage?
        switch data.format {
        case .jpegEncoded, .JPEG2000:
            image = CGImageSourceCreateWithData(data.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        default:
            guard let width = imageInt(dictionary, "Width", "W"), let height = imageInt(dictionary, "Height", "H"),
                  width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
            let bits = imageInt(dictionary, "BitsPerComponent", "BPC") ?? 8
            image = sampledImage(data.data, width: width, height: height, bits: bits, model: .gray, decode: pdfNumbers(dictionary, "Decode"))
        }
        guard let image else { return nil }
        guard let values = grayBytes(image) else { return nil }
        return (values, image.width, image.height)
    }

    private func explicitMaskValues(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef) -> ([UInt8], Int, Int)? {
        guard let width = imageInt(dictionary, "Width", "W"), let height = imageInt(dictionary, "Height", "H"),
              width > 0, height > 0, width <= 16384, height <= 16384,
              let data = pdfData(stream), data.format == .raw else { return nil }
        let rowBytes = (width + 7) / 8
        guard data.data.count >= rowBytes * height, width * height <= 60_000_000 else { return nil }
        let invert = pdfNumbers(dictionary, "Decode")?.first == 1
        var values = [UInt8](repeating: 0, count: width * height)
        data.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for y in 0..<height {
                let row = y * rowBytes
                for x in 0..<width {
                    let bit = (buffer[row + x / 8] >> UInt8(7 - x % 8)) & 1
                    values[y * width + x] = (bit == 0) != invert ? 255 : 0
                }
            }
        }
        return (values, width, height)
    }

    private func grayBytes(_ image: CGImage) -> [UInt8]? {
        var values = [UInt8](repeating: 0, count: image.width * image.height)
        let ok: Bool = values.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? values : nil
    }

    private func resample(_ values: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        if width == toWidth && height == toHeight { return values }
        var out = [UInt8](repeating: 0, count: toWidth * toHeight)
        for y in 0..<toHeight {
            let sy = y * height / toHeight
            for x in 0..<toWidth { out[y * toWidth + x] = values[sy * width + x * width / toWidth] }
        }
        return out
    }

    private func flatten(_ image: CGImage, mask: [UInt8]?, width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            if let mask {
                let bytes = buffer.bindMemory(to: UInt8.self)
                for index in 0..<(width * height) {
                    let a = UInt32(mask[index])
                    if a == 255 { continue }
                    let offset = index * 4
                    bytes[offset] = UInt8(UInt32(bytes[offset]) * a / 255)
                    bytes[offset + 1] = UInt8(UInt32(bytes[offset + 1]) * a / 255)
                    bytes[offset + 2] = UInt8(UInt32(bytes[offset + 2]) * a / 255)
                    bytes[offset + 3] = UInt8(UInt32(bytes[offset + 3]) * a / 255)
                }
            }
            return context.makeImage()
        }
    }

    // MARK: Text

    private func font(for dictionary: CGPDFDictionaryRef) -> SVGFont {
        let key = objectKey(dictionary)
        if let known = fonts[key] { return known }
        let font = SVGFont(dictionary)
        fonts[key] = font
        return font
    }

    private func setFont(_ name: String, size: CGFloat) {
        gs.fontSize = size
        guard let content, let object = CGPDFContentStreamGetResource(content, "Font", name) else { gs.font = nil; return }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { gs.font = nil; return }
        gs.font = font(for: dictionary)
    }

    private func moveText(_ x: CGFloat, _ y: CGFloat) {
        textLineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(textLineMatrix)
        textMatrix = textLineMatrix
    }

    private func nextLine() { moveText(0, -gs.leading) }

    private func showText(_ bytes: [UInt8]) {
        guard let font = gs.font else { return }
        if font.kind == .type3 { showType3(bytes, font: font); return }
        let outlines = CGMutablePath()
        var failed = CGRect.null
        let sizing = CGAffineTransform(a: gs.fontSize * gs.horizontalScale, b: 0, c: 0, d: gs.fontSize, tx: 0, ty: gs.rise)
        font.decode(bytes) { code, cid, length in
            let width = font.width(code: code, cid: cid) / 1000
            let result = font.outline(code: code, cid: cid)
            var placement = sizing.concatenating(textMatrix).concatenating(gs.ctm)
            if font.vertical { placement = CGAffineTransform(translationX: -width / 2, y: -font.verticalOrigin / 1000).concatenating(placement) }
            if result.known {
                if let glyph = result.path { outlines.addPath(glyph, transform: placement) }
            } else {
                failed = failed.union(CGRect(x: 0, y: -0.3, width: max(width, 0.6), height: 1.3).applying(placement))
            }
            let spacing = gs.charSpace + (length == 1 && code == 32 ? gs.wordSpace : 0)
            if font.vertical {
                let advance = font.verticalAdvance / 1000 * gs.fontSize + spacing
                textMatrix = CGAffineTransform(translationX: 0, y: advance).concatenating(textMatrix)
            } else {
                let advance = (width * gs.fontSize + spacing) * gs.horizontalScale
                textMatrix = CGAffineTransform(translationX: advance, y: 0).concatenating(textMatrix)
            }
        }
        paintGlyphs(outlines, failed: failed)
    }

    private func paintGlyphs(_ outlines: CGPath, failed: CGRect) {
        let mode = gs.renderMode
        if mode == 3 { return }
        if !isHidden {
            if !failed.isNull { patch(bounds: failed) }
            if !outlines.isEmpty {
                drawShape(outlines, fill: mode == 0 || mode == 2 || mode == 4 || mode == 6, stroke: mode == 1 || mode == 2 || mode == 5 || mode == 6, evenOdd: false)
            }
        }
        if mode >= 4, !outlines.isEmpty {
            let clip = textClip ?? CGMutablePath()
            clip.addPath(outlines)
            textClip = clip
        }
    }

    private func adjustText(_ amount: CGFloat) {
        guard let font = gs.font else { return }
        let offset = -amount / 1000 * gs.fontSize
        if font.vertical {
            textMatrix = CGAffineTransform(translationX: 0, y: offset).concatenating(textMatrix)
        } else {
            textMatrix = CGAffineTransform(translationX: offset * gs.horizontalScale, y: 0).concatenating(textMatrix)
        }
    }

    private func showText(array: CGPDFArrayRef) {
        for index in 0..<CGPDFArrayGetCount(array) {
            var object: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, index, &object), let object else { continue }
            var string: CGPDFStringRef?
            var number: CGPDFReal = 0
            if CGPDFObjectGetValue(object, .string, &string), let string { showText(pdfBytes(string)) } else if CGPDFObjectGetValue(object, .real, &number) { adjustText(number) }
        }
    }

    private func showType3(_ bytes: [UInt8], font: SVGFont) {
        for byte in bytes {
            let code = Int(byte)
            let width = (font.widths[code] ?? font.defaultWidth) * font.type3Matrix.a
            if gs.renderMode != 3, !isHidden, let procs = font.type3Procs, let name = font.names[code], let stream = pdfStream(procs, name) {
                runCharProc(stream, font: font)
            }
            let spacing = gs.charSpace + (code == 32 ? gs.wordSpace : 0)
            let advance = (width * gs.fontSize + spacing) * gs.horizontalScale
            textMatrix = CGAffineTransform(translationX: advance, y: 0).concatenating(textMatrix)
        }
    }

    private func runCharProc(_ stream: CGPDFStreamRef, font: SVGFont) {
        let key = objectKey(stream)
        guard depth < Self.maxDepth, !activeForms.contains(key) else { return }
        let savedState = gs, savedStack = stack, savedFloor = stackFloor, savedContent = content
        let savedPath = path, savedPoint = pathPoint, savedStart = subpathStart, savedPending = pendingClip
        let savedTextMatrix = textMatrix, savedLine = textLineMatrix, savedClip = textClip, savedLock = colorLocked
        let savedMarks = markedContent, savedHidden = hiddenLayers
        defer {
            gs = savedState; stack = savedStack; stackFloor = savedFloor; content = savedContent
            path = savedPath; pathPoint = savedPoint; subpathStart = savedStart; pendingClip = savedPending
            textMatrix = savedTextMatrix; textLineMatrix = savedLine; textClip = savedClip; colorLocked = savedLock
            markedContent = savedMarks; hiddenLayers = savedHidden
            depth -= 1
            activeForms.remove(key)
        }
        depth += 1
        activeForms.insert(key)
        stackFloor = stack.count
        resetPath()
        let sizing = CGAffineTransform(a: gs.fontSize * gs.horizontalScale, b: 0, c: 0, d: gs.fontSize, tx: 0, ty: gs.rise)
        gs.ctm = font.type3Matrix.concatenating(sizing).concatenating(textMatrix).concatenating(gs.ctm)
        gs.lineWidth = 1
        let resources = font.type3Resources ?? CGPDFStreamGetDictionary(stream)!
        guard let parent = savedContent else { return }
        let glyphStream = CGPDFContentStreamCreateWithStream(stream, resources, parent)
        content = glyphStream
        scan(glyphStream)
        CGPDFContentStreamRelease(glyphStream)
    }

    // MARK: Annotations

    private func drawAnnotations() {
        guard let dictionary = cgPage.dictionary, let annotations = pdfArray(dictionary, "Annots") else { return }
        for index in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { continue }
            let subtype = pdfName(annotation, "Subtype")
            guard subtype != "Popup", let rectangle = pdfNumbers(annotation, "Rect"), rectangle.count >= 4 else { continue }
            gs = GraphicsState(ctm: geometry.base, clipBox: pageRect)
            let flags = pdfInt(pdfNumber(annotation, "F") ?? 0)
            if flags & 2 != 0 || flags & 32 != 0 { continue }
            let rect = CGRect(x: rectangle[0], y: rectangle[1], width: rectangle[2] - rectangle[0], height: rectangle[3] - rectangle[1]).standardized
            // PDFKit redraws form fields from their current values, so their appearance streams can't be trusted.
            guard subtype != "Widget", let appearance = appearanceStream(annotation), let form = CGPDFStreamGetDictionary(appearance) else {
                if subtype != "Link" { patch(bounds: rect.applying(geometry.base)) }
                continue
            }
            // Map the appearance's transformed bounding box onto the annotation rectangle.
            let box = pdfNumbers(form, "BBox") ?? [0, 0, rect.width, rect.height]
            guard box.count >= 4 else { continue }
            let matrix = pdfMatrix(pdfNumbers(form, "Matrix")) ?? .identity
            let bounds = CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1]).standardized.applying(matrix)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let fit = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
                .concatenating(CGAffineTransform(scaleX: rect.width / bounds.width, y: rect.height / bounds.height))
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
            gs.ctm = fit.concatenating(geometry.base)
            drawForm(appearance, dictionary: form)
        }
    }

    private func appearanceStream(_ annotation: CGPDFDictionaryRef) -> CGPDFStreamRef? {
        guard let appearances = pdfDictionary(annotation, "AP") else { return nil }
        if let stream = pdfStream(appearances, "N") { return stream }
        guard let states = pdfDictionary(appearances, "N") else { return nil }
        if let state = pdfName(annotation, "AS"), let stream = pdfStream(states, state) { return stream }
        return pdfStream(states, "Off")
    }

    // MARK: Operators

    private static func interpreter(_ info: UnsafeMutableRawPointer?) -> PDFSVGInterpreter {
        Unmanaged<PDFSVGInterpreter>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var out = [CGFloat](repeating: 0, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            out[index] = value
        }
        return out
    }

    private static func name(_ scanner: CGPDFScannerRef) -> String? {
        var value: UnsafePointer<CChar>?
        return CGPDFScannerPopName(scanner, &value) ? value.map { String(cString: $0) } : nil
    }

    private static func string(_ scanner: CGPDFScannerRef) -> [UInt8]? {
        var value: CGPDFStringRef?
        return CGPDFScannerPopString(scanner, &value) ? value.map(pdfBytes) : nil
    }

    private static let operatorTable: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        func add(_ name: String, _ body: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, name, body) }

        // Graphics state
        add("q") { _, info in
            let run = interpreter(info); guard run.tick() else { return }
            if run.stack.count < 4096 { run.stack.append(run.gs) }
        }
        add("Q") { _, info in
            let run = interpreter(info); guard run.tick() else { return }
            if run.stack.count > run.stackFloor, let state = run.stack.popLast() { run.gs = state }
        }
        add("cm") { s, info in
            let run = interpreter(info); guard run.tick(), let m = pdfMatrix(numbers(s, 6)) else { return }
            run.gs.ctm = m.concatenating(run.gs.ctm)
        }
        add("w") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.lineWidth = n[0] }
        add("J") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.lineCap = pdfInt(n[0]) }
        add("j") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.lineJoin = pdfInt(n[0]) }
        add("M") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.miter = n[0] }
        add("d") { s, info in
            let run = interpreter(info); guard run.tick() else { return }
            var phase: CGPDFReal = 0
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopNumber(s, &phase), CGPDFScannerPopArray(s, &array), let array else { return }
            run.gs.dash = pdfNumbers(array)
            run.gs.dashPhase = phase
        }
        add("gs") { s, info in let run = interpreter(info); guard run.tick(), let n = name(s) else { return }; run.applyExtGState(n) }

        // Paths
        add("m") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 2) else { return }; run.move(CGPoint(x: n[0], y: n[1])) }
        add("l") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 2) else { return }; run.line(CGPoint(x: n[0], y: n[1])) }
        add("c") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 6) else { return }; run.curve(CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]), CGPoint(x: n[4], y: n[5])) }
        add("v") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 4) else { return }; run.curve(nil, CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3])) }
        add("y") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 4) else { return }; run.curve(CGPoint(x: n[0], y: n[1]), nil, CGPoint(x: n[2], y: n[3])) }
        add("h") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.closePath() }
        add("re") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 4) else { return }; run.rect(n[0], n[1], n[2], n[3]) }
        add("W") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.pendingClip = false }
        add("W*") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.pendingClip = true }
        add("n") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.paintPath(fill: false, stroke: false) }
        add("S") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.paintPath(fill: false, stroke: true) }
        add("s") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.closePath(); run.paintPath(fill: false, stroke: true) }
        add("f") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.paintPath(fill: true, stroke: false) }
        add("F") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.paintPath(fill: true, stroke: false) }
        add("f*") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.paintPath(fill: true, stroke: false, evenOdd: true) }
        add("B") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.paintPath(fill: true, stroke: true) }
        add("B*") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.paintPath(fill: true, stroke: true, evenOdd: true) }
        add("b") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.closePath(); run.paintPath(fill: true, stroke: true) }
        add("b*") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.closePath(); run.paintPath(fill: true, stroke: true, evenOdd: true) }

        // Colour
        add("g") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.setColor(.gray, n, stroke: false) }
        add("G") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.setColor(.gray, n, stroke: true) }
        add("rg") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 3) else { return }; run.setColor(.rgb, n, stroke: false) }
        add("RG") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 3) else { return }; run.setColor(.rgb, n, stroke: true) }
        add("k") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 4) else { return }; run.setColor(.cmyk, n, stroke: false) }
        add("K") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 4) else { return }; run.setColor(.cmyk, n, stroke: true) }
        add("cs") { s, info in let run = interpreter(info); guard run.tick(), let n = name(s) else { return }; run.setSpace(n, stroke: false) }
        add("CS") { s, info in let run = interpreter(info); guard run.tick(), let n = name(s) else { return }; run.setSpace(n, stroke: true) }
        add("sc") { s, info in let run = interpreter(info); guard run.tick() else { return }; run.setColorFromOperands(s, stroke: false) }
        add("SC") { s, info in let run = interpreter(info); guard run.tick() else { return }; run.setColorFromOperands(s, stroke: true) }
        add("scn") { s, info in let run = interpreter(info); guard run.tick() else { return }; run.setColorFromOperands(s, stroke: false) }
        add("SCN") { s, info in let run = interpreter(info); guard run.tick() else { return }; run.setColorFromOperands(s, stroke: true) }

        // Text
        add("BT") { _, info in
            let run = interpreter(info); guard run.tick() else { return }
            run.textMatrix = .identity; run.textLineMatrix = .identity
        }
        add("ET") { _, info in
            let run = interpreter(info); guard run.tick() else { return }
            if let clip = run.textClip { run.pushClip(clip, evenOdd: false); run.textClip = nil }
        }
        add("Tc") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.charSpace = n[0] }
        add("Tw") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.wordSpace = n[0] }
        add("Tz") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.horizontalScale = n[0] / 100 }
        add("TL") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.leading = n[0] }
        add("Ts") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.rise = n[0] }
        add("Tr") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 1) else { return }; run.gs.renderMode = pdfInt(n[0]) }
        add("Tf") { s, info in
            let run = interpreter(info); guard run.tick(), let size = numbers(s, 1), let n = name(s) else { return }
            run.setFont(n, size: size[0])
        }
        add("Td") { s, info in let run = interpreter(info); guard run.tick(), let n = numbers(s, 2) else { return }; run.moveText(n[0], n[1]) }
        add("TD") { s, info in
            let run = interpreter(info); guard run.tick(), let n = numbers(s, 2) else { return }
            run.gs.leading = -n[1]
            run.moveText(n[0], n[1])
        }
        add("Tm") { s, info in
            let run = interpreter(info); guard run.tick(), let m = pdfMatrix(numbers(s, 6)) else { return }
            run.textMatrix = m; run.textLineMatrix = m
        }
        add("T*") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.nextLine() }
        add("Tj") { s, info in let run = interpreter(info); guard run.tick(), let bytes = string(s) else { return }; run.showText(bytes) }
        add("'") { s, info in
            let run = interpreter(info); guard run.tick(), let bytes = string(s) else { return }
            run.nextLine(); run.showText(bytes)
        }
        add("\"") { s, info in
            let run = interpreter(info); guard run.tick(), let bytes = string(s), let n = numbers(s, 2) else { return }
            run.gs.wordSpace = n[0]; run.gs.charSpace = n[1]
            run.nextLine(); run.showText(bytes)
        }
        add("TJ") { s, info in
            let run = interpreter(info); guard run.tick() else { return }
            var array: CGPDFArrayRef?
            if CGPDFScannerPopArray(s, &array), let array { run.showText(array: array) }
        }

        // Type 3 glyph descriptions
        add("d1") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.colorLocked = true }

        // Objects
        add("Do") { s, info in let run = interpreter(info); guard run.tick(), let n = name(s) else { return }; run.drawXObject(n) }
        add("sh") { _, info in
            let run = interpreter(info); guard run.tick() else { return }
            run.patch(bounds: run.gs.clipBox)
        }
        add("EI") { s, info in
            let run = interpreter(info); guard run.tick() else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFScannerPopStream(s, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            run.drawImage(stream, dictionary: dictionary, inline: true)
        }

        // Marked content (for optional content)
        add("BMC") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.beginMarkedContent(tag: "", properties: nil) }
        add("EMC") { _, info in let run = interpreter(info); guard run.tick() else { return }; run.endMarkedContent() }
        add("BDC") { s, info in
            let run = interpreter(info); guard run.tick() else { return }
            var object: CGPDFObjectRef?
            guard CGPDFScannerPopObject(s, &object), let object, let tag = name(s) else { return }
            var properties: CGPDFDictionaryRef?
            var propertyName: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object, .dictionary, &properties) {
                // Inline dictionary: nothing else to resolve.
            } else if CGPDFObjectGetValue(object, .name, &propertyName), let propertyName, let content = run.content,
                      let resource = CGPDFContentStreamGetResource(content, "Properties", String(cString: propertyName)) {
                CGPDFObjectGetValue(resource, .dictionary, &properties)
            }
            run.beginMarkedContent(tag: tag, properties: properties)
        }
        return table
    }()
}

extension Optional where Wrapped == [CGFloat] {
    /// Calls `body` with a pointer to the values, or nil when there are none.
    fileprivate func withOptionalBuffer<R>(_ body: (UnsafePointer<CGFloat>?) -> R) -> R {
        guard let self else { return body(nil) }
        return self.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}
