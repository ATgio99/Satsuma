import CoreGraphics
import Foundation
import PDFKit
import zlib

/// Convert to PDF/A-2b. Every page is redrawn through Quartz, the file Quartz writes is rewritten with the
/// PDF/A structure (output intent, XMP, classic xref, /ID), and the bytes are checked again before they reach
/// the user: a file that fails any check is never saved. The checks are structural, not a certified validator.
enum PDFAWriter {
    private static let producer = "Satsuma"
    private static let conditionIdentifier = "sRGB IEC61966-2.1"

    private static let cannotRewrite = ConversionError.encodingFailed("Quartz produced a PDF that cannot be made PDF/A.")
    private static let cannotVerify = ConversionError.encodingFailed("The PDF/A file could not be verified.")
    private static let cannotConvertCMYK = ConversionError.encodingFailed("This PDF's CMYK colors cannot be converted to PDF/A.")
    private static let fontNotEmbedded = ConversionError.encodingFailed("This PDF could not be made PDF/A: a font could not be embedded.")

    private static func unsupported(_ name: String) -> ConversionError {
        .encodingFailed("This PDF could not be made PDF/A: it still contains the unsupported feature /\(name).")
    }

    // MARK: Tool entry

    static func convert(_ source: URL) throws -> URL {
        guard let document = PDFDocument(url: source), !document.isLocked, document.pageCount >= 1 else {
            throw ConversionError.sourceCannotBeRead
        }
        let folder = source.deletingLastPathComponent()
        let working = folder.appendingPathComponent(".satsuma-tool-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: working) }
        try write(document, to: working)
        guard let reopened = PDFDocument(url: working), !reopened.isLocked, reopened.pageCount == document.pageCount else { throw cannotVerify }
        for index in 0..<document.pageCount {
            guard let original = document.page(at: index), let page = reopened.page(at: index) else { throw cannotVerify }
            let wanted = pageSize(of: original), found = page.bounds(for: .cropBox).size
            guard abs(wanted.width - found.width) < 0.01, abs(wanted.height - found.height) < 0.01 else { throw cannotVerify }
        }
        let output = destination(for: source)
        try FileManager.default.moveItem(at: working, to: output)
        return output
    }

    /// `<stem> PDF-A.pdf`, then `<stem> 2 PDF-A.pdf`.
    static func destination(for source: URL) -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(stem) PDF-A.pdf")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(index) PDF-A.pdf")
            index += 1
        }
        return candidate
    }

    static func write(_ document: PDFDocument, to output: URL) throws {
        let folder = output.deletingLastPathComponent()
        let quartz = folder.appendingPathComponent(".satsuma-pdfa-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: quartz) }
        try regenerate(document, to: quartz)
        let rewritten = try rewrite(Data(contentsOf: quartz, options: .mappedIfSafe), attributes: document.documentAttributes ?? [:])
        try validate(rewritten, expectedPages: document.pageCount)
        try rewritten.write(to: output)
    }

    // MARK: Quartz stage

    /// The size a page is seen at, with 90 and 270 degree rotation applied.
    private static func pageSize(of page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .cropBox)
        return abs(page.rotation) % 180 == 90 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    }

    private static func regenerate(_ document: PDFDocument, to url: URL) throws {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ConversionError.encodingFailed("The sRGB color profile is unavailable.")
        }
        let intent: [CFString: Any] = [kCGPDFXOutputIntentSubtype: "GTS_PDFA1",
                                       kCGPDFXOutputConditionIdentifier: conditionIdentifier,
                                       kCGPDFXInfo: conditionIdentifier,
                                       kCGPDFXDestinationOutputProfile: sRGB]
        let auxiliary: [CFString: Any] = [kCGPDFContextCreator: producer, kCGPDFContextOutputIntent: intent]
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &defaultBox, auxiliary as CFDictionary) else {
            throw ConversionError.encodingFailed("Could not create the PDF/A file.")
        }
        // Forces a catalog /Metadata object, replaced by the rewrite.
        context.addDocumentMetadata(Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8) as CFData)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw ConversionError.encodingFailed("PDF page \(index + 1) has invalid dimensions.")
            }
            let width = pageSize(of: page).width, height = pageSize(of: page).height
            guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                throw ConversionError.encodingFailed("PDF page \(index + 1) has invalid dimensions.")
            }
            guard (3...14400).contains(width), (3...14400).contains(height) else {
                throw ConversionError.encodingFailed("PDF page \(index + 1) is outside the page sizes PDF/A allows (3 to 14,400 points per side).")
            }
            guard !FormFanOut.exceedsLimit(page) else {
                throw ConversionError.encodingFailed("PDF page \(index + 1) is too complex to convert.")
            }
            var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
            let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: boxData as CFData] as CFDictionary)
            page.draw(with: .cropBox, to: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    // MARK: Rewrite

    private static func rewrite(_ data: Data, attributes: [AnyHashable: Any]) throws -> Data {
        var file: PDFAFile
        do { file = try PDFAFile(parsing: [UInt8](data)) } catch { throw cannotRewrite }
        guard case .ref(let rootNumber)? = file.trailer["Root"], let catalog = file.dict(.ref(rootNumber)),
              catalog["Type"]?.nameValue == "Catalog", case .ref(let metadataNumber)? = catalog["Metadata"],
              catalog["OutputIntents"] != nil else { throw cannotRewrite }
        let pageNumbers: [Int]
        do { pageNumbers = try file.pageNumbers(root: rootNumber) } catch { throw cannotRewrite }

        // Quartz's structure tree refers to objects it never writes. Level B needs no tags, and the catalog carries only the mandatory keys.
        var cleanCatalog = PDFADict()
        for key in ["Type", "Pages", "Metadata", "OutputIntents"] { cleanCatalog[key] = catalog[key] }
        file.objects[rootNumber]?.value = .dict(cleanCatalog)

        // CMYK: Quartz keeps device CMYK from the source, which the sRGB output intent does not cover.
        var usesCMYK = file.objects.values.contains { $0.value.containsName("DeviceCMYK") }
        let streams: [PDFAFile.ContentStream]
        do { streams = try file.contentStreams(pages: pageNumbers) } catch { throw cannotRewrite }
        for stream in streams {
            guard let bytes = file.decodedStream(stream.number) else { throw cannotRewrite }
            let scan = PDFAContentScan(bytes)
            if scan.usesCMYK { usesCMYK = true }
        }
        if usesCMYK {
            try applyCMYKProfile(&file, pages: pageNumbers, streams: streams)
        }

        // Per-object fixes required by PDF/A.
        for (number, object) in file.objects {
            file.objects[number]?.value = sanitized(object.value)
        }

        // Replace the Quartz placeholder metadata and Info dictionary.
        let info = try documentInfo(attributes)
        let xmp = xmpPacket(info)
        let infoNumber = (file.objects.keys.max() ?? 0) + 1
        file.objects[infoNumber] = PDFAObject(value: .dict(info.dictionary))
        var metadataDict = PDFADict()
        metadataDict["Type"] = .name("Metadata")
        metadataDict["Subtype"] = .name("XML")
        file.objects[metadataNumber] = PDFAObject(value: .dict(metadataDict), inlineStream: [UInt8](xmp.utf8))

        return try serialize(file, root: rootNumber, info: infoNumber)
    }

    /// Adds the Generic CMYK ICC profile and makes every use of device CMYK device independent.
    private static func applyCMYKProfile(_ file: inout PDFAFile, pages: [Int], streams: [PDFAFile.ContentStream]) throws {
        guard let space = CGColorSpace(name: CGColorSpace.genericCMYK), let icc = space.copyICCData() as Data? else {
            throw ConversionError.encodingFailed("The CMYK color profile is unavailable.")
        }
        let iccNumber = (file.objects.keys.max() ?? 0) + 1
        let arrayNumber = iccNumber + 1
        // Named device CMYK anywhere (images, shadings, groups, Indexed and DeviceN bases) becomes the ICCBased space.
        for (number, object) in file.objects {
            file.objects[number]?.value = object.value.replacingDeviceCMYK(with: .ref(arrayNumber))
        }
        var iccDict = PDFADict()
        iccDict["N"] = .int(4)
        file.objects[iccNumber] = PDFAObject(value: .dict(iccDict), inlineStream: [UInt8](icc))
        file.objects[arrayNumber] = PDFAObject(value: .array([.name("ICCBased"), .ref(iccNumber)]))

        // `k`, `K` and `/DeviceCMYK cs` inside content streams need DefaultCMYK in the resources in force.
        var owners = Set(pages)
        for stream in streams { if let owner = stream.resourceOwner { owners.insert(owner) } }
        for owner in owners {
            guard var dict = file.objects[owner]?.value.dictValue else { throw cannotConvertCMYK }
            let resources = file.inheritedResources(owner)
            switch resources {
            case .ref(let number):
                guard var resourceDict = file.objects[number]?.value.dictValue else { throw cannotConvertCMYK }
                file.setDefaultCMYK(in: &resourceDict, to: arrayNumber)
                file.objects[number]?.value = .dict(resourceDict)
                dict["Resources"] = .ref(number)
            case .dict(var resourceDict):
                file.setDefaultCMYK(in: &resourceDict, to: arrayNumber)
                dict["Resources"] = .dict(resourceDict)
            default:
                var resourceDict = PDFADict()
                file.setDefaultCMYK(in: &resourceDict, to: arrayNumber)
                dict["Resources"] = .dict(resourceDict)
            }
            file.objects[owner]?.value = .dict(dict)
        }
    }

    /// Interpolation off, CIDToGIDMap present, and no optional font subset lists that Quartz cannot guarantee.
    private static func sanitized(_ value: PDFAValue) -> PDFAValue {
        switch value {
        case .array(let items): return .array(items.map(sanitized))
        case .dict(var dict):
            dict.entries = dict.entries.map { ($0.0, sanitized($0.1)) }
            if case .bool(true)? = dict["Interpolate"] { dict["Interpolate"] = .bool(false) }
            if dict["Subtype"]?.nameValue == "CIDFontType2", dict["CIDToGIDMap"] == nil { dict["CIDToGIDMap"] = .name("Identity") }
            if dict["Type"]?.nameValue == "FontDescriptor" {
                dict.remove("CIDSet")
                dict.remove("CharSet")
            }
            return .dict(dict)
        default: return value
        }
    }

    // MARK: Metadata

    private struct DocumentInfo {
        var title: String?, author: String?, subject: String?, keywords: String?
        var created: Date, modified: Date

        var dictionary: PDFADict {
            var dict = PDFADict()
            dict["Producer"] = .string(PDFAWriter.pdfString(PDFAWriter.producer))
            dict["Creator"] = .string(PDFAWriter.pdfString(PDFAWriter.producer))
            dict["CreationDate"] = .string([UInt8](PDFAWriter.pdfDate(created).utf8))
            dict["ModDate"] = .string([UInt8](PDFAWriter.pdfDate(modified).utf8))
            if let title { dict["Title"] = .string(PDFAWriter.pdfString(title)) }
            if let author { dict["Author"] = .string(PDFAWriter.pdfString(author)) }
            if let subject { dict["Subject"] = .string(PDFAWriter.pdfString(subject)) }
            if let keywords { dict["Keywords"] = .string(PDFAWriter.pdfString(keywords)) }
            return dict
        }
    }

    private static func documentInfo(_ attributes: [AnyHashable: Any]) throws -> DocumentInfo {
        func text(_ key: PDFDocumentAttribute) -> String? {
            let value = attributes[key] ?? attributes[key.rawValue]
            let string = (value as? String) ?? (value as? [String])?.joined(separator: ", ")
            return string.flatMap(cleaned)
        }
        let now = Date()
        let source = (attributes[PDFDocumentAttribute.creationDateAttribute] ?? attributes[PDFDocumentAttribute.creationDateAttribute.rawValue]) as? Date
        let created = source.flatMap { (1...9999).contains(utc($0).year ?? 0) ? $0 : nil } ?? now
        return DocumentInfo(title: text(.titleAttribute), author: text(.authorAttribute),
                            subject: text(.subjectAttribute), keywords: text(.keywordsAttribute),
                            created: created, modified: now)
    }

    /// Keeps what XML can carry and what fits a PDF string (32,767 bytes as UTF-16 with a byte order mark).
    private static func cleaned(_ value: String) -> String? {
        let scalars = value.unicodeScalars.filter { $0.value >= 0x20 && ![0xFEFF, 0xFFFE, 0xFFFF].contains($0.value) && !(0x7F...0x9F).contains($0.value) }
        var units = 0
        let kept = scalars.prefix { scalar in
            units += UTF16.width(scalar)
            return units <= 16000
        }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func utc(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private static func pdfDate(_ date: Date) -> String {
        let c = utc(date)
        return String(format: "D:%04d%02d%02d%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private static func xmpDate(_ date: Date) -> String {
        let c = utc(date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private static func pdfString(_ text: String) -> [UInt8] {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return [UInt8](text.utf8) }
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in text.utf16 { bytes.append(UInt8(unit >> 8)); bytes.append(UInt8(unit & 0xFF)) }
        return bytes
    }

    private static func xmpPacket(_ info: DocumentInfo) -> String {
        var lines = ["<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>",
                     "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">",
                     "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">",
                     "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
                     "<pdfaid:part>2</pdfaid:part>",
                     "<pdfaid:conformance>B</pdfaid:conformance>",
                     "<xmp:CreatorTool>\(producer)</xmp:CreatorTool>",
                     "<xmp:CreateDate>\(xmpDate(info.created))</xmp:CreateDate>",
                     "<xmp:ModifyDate>\(xmpDate(info.modified))</xmp:ModifyDate>",
                     "<xmp:MetadataDate>\(xmpDate(info.modified))</xmp:MetadataDate>",
                     "<pdf:Producer>\(producer)</pdf:Producer>",
                     "<dc:format>application/pdf</dc:format>"]
        if let title = info.title {
            lines.append("<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(title.xmlEscaped)</rdf:li></rdf:Alt></dc:title>")
        }
        if let author = info.author {
            lines.append("<dc:creator><rdf:Seq><rdf:li>\(author.xmlEscaped)</rdf:li></rdf:Seq></dc:creator>")
        }
        if let subject = info.subject {
            lines.append("<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(subject.xmlEscaped)</rdf:li></rdf:Alt></dc:description>")
        }
        if let keywords = info.keywords { lines.append("<pdf:Keywords>\(keywords.xmlEscaped)</pdf:Keywords>") }
        lines += ["</rdf:Description>", "</rdf:RDF>", "</x:xmpmeta>", "<?xpacket end=\"w\"?>"]
        return lines.joined(separator: "\n")
    }

    // MARK: Output

    private static func serialize(_ file: PDFAFile, root: Int, info: Int) throws -> Data {
        // Only objects reachable from the catalog and Info survive, numbered without gaps so the xref has one free entry.
        var numbers: [Int: Int] = [:]
        var order: [Int] = []
        var pending = [root, info]
        while let number = pending.popLast() {
            guard numbers[number] == nil, let object = file.objects[number] else { continue }
            numbers[number] = order.count + 1
            order.append(number)
            pending.append(contentsOf: object.value.references)
        }
        func renumbered(_ value: PDFAValue) -> PDFAValue { value.renumbered { numbers[$0] } }

        var out = Data("%PDF-1.7\n%".utf8)
        out.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for number in order {
            guard let object = file.objects[number] else { throw cannotRewrite }
            offsets.append(out.count)
            out.append(Data("\(offsets.count) 0 obj\n".utf8))
            var value = renumbered(object.value)
            if object.hasStream {
                guard let bytes = file.rawStream(number), var dict = value.dictValue else { throw cannotRewrite }
                dict.remove("Length")
                dict["Length"] = .int(bytes.count)
                value = .dict(dict)
                out.append(Data(value.serialized.utf8))
                out.append(Data("\nstream\n".utf8))
                out.append(contentsOf: bytes)
                out.append(Data("\nendstream\nendobj\n".utf8))
            } else {
                out.append(Data(value.serialized.utf8))
                out.append(Data("\nendobj\n".utf8))
            }
        }
        let xrefOffset = out.count
        var xref = "xref\n0 \(order.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { xref += String(format: "%010d 00000 n \n", offset) }
        var idBytes = [UInt8](repeating: 0, count: 16)
        for index in idBytes.indices { idBytes[index] = UInt8.random(in: 0...255) }
        let id = idBytes.map { String(format: "%02X", $0) }.joined()
        guard let newRoot = numbers[root], let newInfo = numbers[info] else { throw cannotRewrite }
        xref += "trailer\n<< /Size \(order.count + 1) /Root \(newRoot) 0 R /Info \(newInfo) 0 R /ID [<\(id)> <\(id)>] >>\nstartxref\n\(xrefOffset)\n%%EOF"
        out.append(Data(xref.utf8))
        return out
    }

    // MARK: Final validation

    private static let forbiddenNames: Set<String> = ["Encrypt", "JavaScript", "JS", "AA", "OpenAction", "Launch", "Annots", "AcroForm", "XFA",
                                                     "Movie", "Sound", "Screen", "Rendition", "RichMedia", "3D", "EmbeddedFiles", "EmbeddedFile",
                                                     "EF", "Filespec", "Ref", "OPI", "Alternates", "PS", "TR", "HTP", "LZWDecode", "Crypt", "DeviceCMYK"]
    private static let blendModes: Set<String> = ["Normal", "Compatible", "Multiply", "Screen", "Overlay", "Darken", "Lighten", "ColorDodge", "ColorBurn",
                                                 "HardLight", "SoftLight", "Difference", "Exclusion", "Hue", "Saturation", "Color", "Luminosity"]
    private static let streamFilters: Set<String> = ["FlateDecode", "DCTDecode", "JPXDecode", "CCITTFaxDecode", "JBIG2Decode", "ASCII85Decode", "ASCIIHexDecode", "RunLengthDecode"]

    /// Checks the exact bytes about to be saved. Any failure means no output.
    static func validate(_ data: Data, expectedPages: Int) throws {
        let bytes = [UInt8](data)
        let file: PDFAFile
        do { file = try PDFAFile(parsing: bytes, strict: true) } catch { throw cannotVerify }

        // Header, trailing bytes and trailer.
        let header: [UInt8] = Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
        guard bytes.starts(with: header), bytes.suffix(5).elementsEqual(Array("%%EOF".utf8)) else { throw cannotVerify }
        guard Set(file.trailer.entries.map { $0.0 }) == ["Size", "Root", "Info", "ID"],
              case .ref(let root)? = file.trailer["Root"], case .ref(let info)? = file.trailer["Info"],
              case .array(let id)? = file.trailer["ID"], id.count == 2,
              case .string(let first) = id[0], case .string(let second) = id[1], first == second, first.count == 16 else { throw cannotVerify }

        // Every value: forbidden names, dangling references.
        for object in file.objects.values {
            for name in object.value.checkedNames where forbiddenNames.contains(name) { throw unsupported(name) }
            for reference in object.value.references where file.objects[reference] == nil { throw cannotVerify }
            try checkLimits(object.value)
        }

        // Catalog, metadata, output intent.
        guard let catalog = file.dict(.ref(root)), catalog["Type"]?.nameValue == "Catalog",
              Set(catalog.entries.map { $0.0 }) == ["Type", "Pages", "Metadata", "OutputIntents"] else { throw cannotVerify }
        try checkMetadata(file, catalog: catalog, info: file.dict(.ref(info)))
        try checkOutputIntent(file, catalog: catalog)

        // Objects by kind.
        var iccProfiles = Set<Int>()
        for object in file.objects.values { iccProfiles.formUnion(object.value.iccProfileReferences) }
        try checkSpotColors(file)
        for (number, object) in file.objects {
            guard let dict = object.value.dictValue else { continue }
            let type = file.resolve(dict["Type"])?.nameValue
            if type == "ObjStm" || type == "XRef" { throw cannotVerify }
            if object.hasStream { try checkStream(dict, file: file, number: number) }
            if case .bool(true)? = dict["Interpolate"] { throw unsupported("Interpolate") }
            if let intent = dict["Intent"], !PDFAContentScan.intents.contains(file.resolve(intent)?.nameValue ?? "") { throw unsupported("Intent") }
            if type == "Font" { try checkFont(dict, file: file) }
            if type == "ExtGState" { try checkExtGState(dict, file: file) }
            if iccProfiles.contains(number) { try checkICC(file, number: number, dict: dict) }
            if let group = file.dict(dict["Group"]), file.resolve(group["S"])?.nameValue != "Transparency" { throw cannotVerify }
        }

        // Pages and content.
        let pages: [Int]
        do { pages = try file.pageNumbers(root: root) } catch { throw cannotVerify }
        guard pages.count == expectedPages, expectedPages >= 1 else { throw cannotVerify }
        for number in pages {
            guard let page = file.dict(.ref(number)) else { throw cannotVerify }
            guard case .array(let box)? = file.resolve(page["MediaBox"]), box.count == 4,
                  let x0 = box[0].numberValue, let y0 = box[1].numberValue, let x1 = box[2].numberValue, let y1 = box[3].numberValue,
                  (3...14400).contains(abs(x1 - x0)), (3...14400).contains(abs(y1 - y0)) else { throw cannotVerify }
        }
        let streams: [PDFAFile.ContentStream]
        do { streams = try file.contentStreams(pages: pages) } catch { throw cannotVerify }
        for stream in streams {
            guard let content = file.decodedStream(stream.number) else { throw cannotVerify }
            let scan = PDFAContentScan(content, identityFonts: identityFonts(file, owner: stream.resourceOwner ?? stream.page))
            guard scan.maxDepth <= 28, !scan.badInlineImage, !scan.badRenderingIntent, !scan.hasLongString else { throw cannotVerify }
            if scan.showsNotdef { throw unsupported(".notdef") }
            if scan.usesCMYK {
                guard let owner = stream.resourceOwner ?? stream.page,
                      let colorSpaces = file.dict(file.dict(file.inheritedResources(owner))?["ColorSpace"]),
                      colorSpaces["DefaultCMYK"] != nil else { throw cannotConvertCMYK }
            }
        }

        // PDFKit must open the very same bytes as an unlocked document with the same pages.
        guard let reopened = PDFDocument(data: data), !reopened.isLocked, reopened.pageCount == expectedPages else { throw cannotVerify }
    }

    /// Resource names of the fonts where the two-byte code 0 can only be glyph 0, `.notdef`.
    private static func identityFonts(_ file: PDFAFile, owner: Int?) -> Set<String> {
        guard let owner, let fonts = file.dict(file.dict(file.inheritedResources(owner))?["Font"]) else { return [] }
        return Set(fonts.entries.filter { _, value in
            guard let font = file.dict(value), file.resolve(font["Subtype"])?.nameValue == "Type0",
                  file.resolve(font["Encoding"])?.nameValue?.hasPrefix("Identity") == true,
                  case .array(let descendants)? = file.resolve(font["DescendantFonts"]), let cidFont = file.dict(descendants.first) else { return false }
            return file.resolve(cidFont["Subtype"])?.nameValue == "CIDFontType0" || file.resolve(cidFont["CIDToGIDMap"])?.nameValue == "Identity"
        }.map { $0.0 })
    }

    /// ISO 19005-2, 6.2.4.4: DeviceN spot colorants are described in /Colorants, and one Separation name means one colour.
    private static func checkSpotColors(_ file: PDFAFile) throws {
        var separations: [String: String] = [:]
        for object in file.objects.values {
            for space in object.value.spotSpaces {
                if space[0].nameValue == "DeviceN" {
                    guard space.count >= 4, case .array(let names)? = file.resolve(space[1]) else { throw cannotVerify }
                    let colorants = file.dict(file.dict(space.count > 4 ? space[4] : nil)?["Colorants"])
                    for name in names.compactMap({ file.resolve($0)?.nameValue })
                    where !["Cyan", "Magenta", "Yellow", "Black", "None"].contains(name) && colorants?[name] == nil { throw unsupported("DeviceN") }
                } else if space.count == 4, let name = file.resolve(space[1])?.nameValue {
                    let definition = fingerprint(space[2], file: file) + "|" + fingerprint(space[3], file: file)
                    if separations.updateValue(definition, forKey: name).map({ $0 != definition }) == true { throw unsupported("Separation") }
                }
            }
        }
    }

    /// Text that is equal for equal content, whichever object numbers the content ended up under.
    private static func fingerprint(_ value: PDFAValue, file: PDFAFile, depth: Int = 0) -> String {
        guard depth < 16 else { return "" }
        switch value {
        case .ref(let number):
            guard let object = file.objects[number] else { return "" }
            let stream = object.hasStream ? file.rawStream(number).map { "#\($0.count):\($0.hashValue)" } ?? "" : ""
            return fingerprint(object.value, file: file, depth: depth + 1) + stream
        case .array(let items): return "[" + items.map { fingerprint($0, file: file, depth: depth + 1) }.joined(separator: " ") + "]"
        case .dict(let dict):
            let entries = dict.entries.filter { $0.0 != "Length" }.sorted { $0.0 < $1.0 }
            return "<" + entries.map { "\($0.0)=" + fingerprint($0.1, file: file, depth: depth + 1) }.joined(separator: " ") + ">"
        default: return value.serialized
        }
    }

    private static func checkLimits(_ value: PDFAValue) throws {
        switch value {
        case .int(let number): guard abs(number) <= 2_147_483_647 else { throw cannotVerify }
        case .real(let text): guard let number = Double(text), abs(number) <= 3.403e38 else { throw cannotVerify }
        case .name(let name): guard name.utf8.count <= 127 else { throw cannotVerify }
        case .string(let bytes): guard bytes.count <= 32767 else { throw cannotVerify }
        case .array(let items): for item in items { try checkLimits(item) }
        case .dict(let dict): for entry in dict.entries { try checkLimits(.name(entry.0)); try checkLimits(entry.1) }
        default: break
        }
    }

    private static func checkStream(_ dict: PDFADict, file: PDFAFile, number: Int) throws {
        for key in ["F", "FFilter", "FDecodeParms"] where dict[key] != nil { throw cannotVerify }
        guard let filter = dict["Filter"] else { return }
        let names: [String]
        switch file.resolve(filter) {
        case .name(let name)?: names = [name]
        case .array(let items)?: names = items.compactMap { file.resolve($0)?.nameValue }
        default: throw cannotVerify
        }
        for name in names where !streamFilters.contains(name) { throw unsupported(name) }
        if names.contains("JPXDecode"), let raw = file.rawStream(number), !isAcceptableJPEG2000(raw, hasColorSpace: dict["ColorSpace"] != nil) { throw cannotVerify }
    }

    /// JPX rules of PDF/A-2 that can be read from the box structure: JP2 signature and a usable colour specification.
    private static func isAcceptableJPEG2000(_ bytes: [UInt8], hasColorSpace: Bool) -> Bool {
        let signature: [UInt8] = [0, 0, 0, 12, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
        guard bytes.starts(with: signature) else { return false }
        if hasColorSpace { return true }
        func u32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        var position = 12
        while position + 8 <= bytes.count {
            let length = u32(position)
            guard length >= 8, position + length <= bytes.count else { return false }
            if Array(bytes[(position + 4)..<(position + 8)]) == Array("jp2h".utf8) {
                var inner = position + 8
                var colors = 0, method: UInt8 = 0, enumerated = 0
                while inner + 8 <= position + length {
                    let size = u32(inner)
                    guard size >= 8, inner + size <= position + length else { return false }
                    if Array(bytes[(inner + 4)..<(inner + 8)]) == Array("colr".utf8), inner + 11 <= position + length {
                        colors += 1
                        method = bytes[inner + 8]
                        if method == 1, inner + 15 <= position + length { enumerated = u32(inner + 11) }
                    }
                    inner += size
                }
                guard colors == 1 else { return false }
                return method == 1 ? [16, 17, 18].contains(enumerated) : method == 2
            }
            position += length
        }
        return false
    }

    private static func checkFont(_ dict: PDFADict, file: PDFAFile) throws {
        guard let subtype = file.resolve(dict["Subtype"])?.nameValue else { throw fontNotEmbedded }
        if subtype == "Type3" { return }
        if subtype == "Type0" {
            guard case .array(let descendants)? = file.resolve(dict["DescendantFonts"]), descendants.count == 1,
                  file.dict(descendants[0]) != nil else { throw fontNotEmbedded }
            if case .name(let encoding)? = file.resolve(dict["Encoding"]) {
                guard encoding == "Identity-H" || encoding == "Identity-V" else { throw fontNotEmbedded }
            } else if !file.isStream(dict["Encoding"]) { throw fontNotEmbedded }
            return
        }
        guard let descriptor = file.dict(dict["FontDescriptor"]) else { throw fontNotEmbedded }
        let program = descriptor["FontFile"] ?? descriptor["FontFile2"] ?? descriptor["FontFile3"]
        guard file.isStream(program),
              ["FontName", "Flags", "FontBBox", "ItalicAngle", "Ascent", "Descent", "StemV"].allSatisfy({ descriptor[$0] != nil }),
              file.resolve(dict["BaseFont"])?.nameValue == file.resolve(descriptor["FontName"])?.nameValue else { throw fontNotEmbedded }
        if subtype == "TrueType" || subtype == "Type1" || subtype == "MMType1",
           !["FirstChar", "LastChar", "Widths"].allSatisfy({ dict[$0] != nil }) { throw fontNotEmbedded }
        if subtype == "CIDFontType2", file.resolve(dict["CIDToGIDMap"]) == nil { throw fontNotEmbedded }
        if subtype == "TrueType" {
            guard case .int(let flags)? = file.resolve(descriptor["Flags"]) else { throw fontNotEmbedded }
            let symbolic = flags & 4 != 0, nonSymbolic = flags & 32 != 0
            guard symbolic != nonSymbolic else { throw fontNotEmbedded }
            if symbolic {
                guard file.resolve(dict["Encoding"]) == nil, let number = program?.referenceNumber, let font = file.decodedStream(number),
                      hasPDFACmap(font) else { throw fontNotEmbedded }
            } else {
                switch file.resolve(dict["Encoding"]) {
                case .name(let name)?:
                    guard name == "MacRomanEncoding" || name == "WinAnsiEncoding" else { throw fontNotEmbedded }
                case .dict(let encoding)?:
                    guard let base = file.resolve(encoding["BaseEncoding"])?.nameValue, base == "MacRomanEncoding" || base == "WinAnsiEncoding",
                          encoding["Differences"] == nil else { throw fontNotEmbedded }
                default: throw fontNotEmbedded
                }
            }
        }
    }

    /// A symbolic TrueType font's cmap holds exactly one encoding, or the Microsoft Symbol (3,0) one.
    private static func hasPDFACmap(_ font: [UInt8]) -> Bool {
        func u16(_ at: Int) -> Int { Int(font[at]) << 8 | Int(font[at + 1]) }
        func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }
        guard font.count >= 12 else { return false }
        let tables = u16(4)
        guard font.count >= 12 + tables * 16 else { return false }
        for table in 0..<tables where Array(font[(12 + table * 16)..<(16 + table * 16)]) == Array("cmap".utf8) {
            let offset = u32(16 + table * 16 + 4)
            guard offset + 4 <= font.count else { return false }
            let count = u16(offset + 2)
            guard offset + 4 + count * 8 <= font.count else { return false }
            if count == 1 { return true }
            for index in 0..<count where u16(offset + 4 + index * 8) == 3 && u16(offset + 6 + index * 8) == 0 { return true }
            return false
        }
        return false
    }

    private static func checkExtGState(_ dict: PDFADict, file: PDFAFile) throws {
        if let transfer = dict["TR2"], file.resolve(transfer)?.nameValue != "Default" { throw unsupported("TR2") }
        if let mode = dict["BM"] {
            let modes: [String?]
            switch file.resolve(mode) {
            case .name(let name)?: modes = [name]
            case .array(let items)?: modes = items.map { file.resolve($0)?.nameValue }
            default: throw cannotVerify
            }
            for name in modes where name == nil || !blendModes.contains(name!) { throw unsupported("BM") }
        }
        if case .int(1)? = file.resolve(dict["OPM"]),
           file.resolve(dict["OP"])?.boolValue == true || file.resolve(dict["op"])?.boolValue == true { throw cannotConvertCMYK }
    }

    private static func checkICC(_ file: PDFAFile, number: Int, dict: PDFADict) throws {
        guard case .int(let components)? = file.resolve(dict["N"]), let profile = file.decodedStream(number), iccIsValid(profile, components: components) else { throw cannotVerify }
    }

    private static func iccIsValid(_ profile: [UInt8], components: Int, classes: Set<String> = ["mntr", "prtr", "scnr", "spac"]) -> Bool {
        guard profile.count >= 128, Array(profile[36..<40]) == Array("acsp".utf8), (2...4).contains(profile[8]) else { return false }
        guard classes.contains(String(decoding: profile[12..<16], as: UTF8.self)) else { return false }
        let expected = ["GRAY": 1, "RGB ": 3, "CMYK": 4, "Lab ": 3][String(decoding: profile[16..<20], as: UTF8.self)]
        return expected == components
    }

    private static func checkOutputIntent(_ file: PDFAFile, catalog: PDFADict) throws {
        guard case .array(let intents)? = file.resolve(catalog["OutputIntents"]), intents.count == 1, let intent = file.dict(intents[0]),
              file.resolve(intent["Type"])?.nameValue == "OutputIntent", file.resolve(intent["S"])?.nameValue == "GTS_PDFA1",
              case .string(let identifier)? = file.resolve(intent["OutputConditionIdentifier"]), identifier == [UInt8](conditionIdentifier.utf8),
              let reference = intent["DestOutputProfile"]?.referenceNumber, let profileDict = file.objects[reference]?.value.dictValue,
              case .int(3)? = file.resolve(profileDict["N"]), let profile = file.decodedStream(reference),
              iccIsValid(profile, components: 3, classes: ["mntr", "prtr"]) else { throw cannotVerify }
    }

    private static func checkMetadata(_ file: PDFAFile, catalog: PDFADict, info: PDFADict?) throws {
        guard let info, let number = catalog["Metadata"]?.referenceNumber, let object = file.objects[number], object.hasStream,
              let dict = object.value.dictValue, file.resolve(dict["Type"])?.nameValue == "Metadata",
              file.resolve(dict["Subtype"])?.nameValue == "XML", dict["Filter"] == nil,
              let raw = file.rawStream(number), let xml = String(bytes: raw, encoding: .utf8),
              xml.hasPrefix("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"), xml.hasSuffix("<?xpacket end=\"w\"?>"),
              let document = try? XMLDocument(xmlString: xml) else { throw cannotVerify }
        func text(_ local: String, _ path: String = "") -> String? {
            (try? document.nodes(forXPath: "//*[local-name()='\(local)']\(path)"))?.first?.stringValue
        }
        guard text("part") == "2", text("conformance") == "B" else { throw cannotVerify }
        func infoText(_ key: String) -> String? {
            guard case .string(let bytes)? = file.resolve(info[key]) else { return nil }
            if bytes.starts(with: [0xFE, 0xFF]) {
                let units = stride(from: 2, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
                return String(decoding: units, as: UTF16.self)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        func xmpFromInfo(_ date: String?) -> String? {
            guard let date, date.count == 17 else { return nil }
            let c = Array(date.dropFirst(2).dropLast())
            return "\(String(c[0..<4]))-\(String(c[4..<6]))-\(String(c[6..<8]))T\(String(c[8..<10])):\(String(c[10..<12])):\(String(c[12..<14]))Z"
        }
        guard xmpFromInfo(infoText("CreationDate")) == text("CreateDate"), xmpFromInfo(infoText("ModDate")) == text("ModifyDate"),
              infoText("Producer") == text("Producer"), infoText("Creator") == text("CreatorTool"),
              infoText("Title") == text("title", "//*[local-name()='li']"), infoText("Author") == text("creator", "//*[local-name()='li']"),
              infoText("Subject") == text("description", "//*[local-name()='li']"), infoText("Keywords") == text("Keywords") else { throw cannotVerify }
    }
}

// MARK: - PDF objects

struct PDFADict {
    var entries: [(String, PDFAValue)] = []

    subscript(key: String) -> PDFAValue? {
        get { entries.first { $0.0 == key }?.1 }
        set {
            if let index = entries.firstIndex(where: { $0.0 == key }) {
                if let newValue { entries[index].1 = newValue } else { entries.remove(at: index) }
            } else if let newValue { entries.append((key, newValue)) }
        }
    }

    mutating func remove(_ key: String) { self[key] = nil }
}

indirect enum PDFAValue {
    case null
    case bool(Bool)
    case int(Int)
    case real(String)
    case string([UInt8])
    case name(String)
    case array([PDFAValue])
    case dict(PDFADict)
    case ref(Int)

    var nameValue: String? { if case .name(let name) = self { return name }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var dictValue: PDFADict? { if case .dict(let dict) = self { return dict }; return nil }
    var referenceNumber: Int? { if case .ref(let number) = self { return number }; return nil }
    var numberValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .real(let text): return Double(text)
        default: return nil
        }
    }

    func containsName(_ target: String) -> Bool {
        switch self {
        case .name(let name): return name == target
        case .array(let items): return items.contains { $0.containsName(target) }
        case .dict(let dict): return dict.entries.contains { $0.1.containsName(target) }
        default: return false
        }
    }

    /// Replaces the name wherever it is a value; an ICC stream's optional /Alternate is dropped instead.
    func replacingDeviceCMYK(with replacement: PDFAValue) -> PDFAValue {
        switch self {
        case .name("DeviceCMYK"): return replacement
        case .array(let items): return .array(items.map { $0.replacingDeviceCMYK(with: replacement) })
        case .dict(var dict):
            if dict["Alternate"]?.nameValue == "DeviceCMYK" { dict.remove("Alternate") }
            dict.entries = dict.entries.map { ($0.0, $0.1.replacingDeviceCMYK(with: replacement)) }
            return .dict(dict)
        default: return self
        }
    }

    /// Streams used as ICC profiles by `[ /ICCBased n 0 R ]` arrays, direct or nested.
    var iccProfileReferences: [Int] {
        switch self {
        case .array(let items):
            if items.count == 2, items[0].nameValue == "ICCBased", let number = items[1].referenceNumber { return [number] }
            return items.flatMap { $0.iccProfileReferences }
        case .dict(let dict): return dict.entries.flatMap { $0.1.iccProfileReferences }
        default: return []
        }
    }

    var references: [Int] {
        switch self {
        case .ref(let number): return [number]
        case .array(let items): return items.flatMap { $0.references }
        case .dict(let dict): return dict.entries.flatMap { $0.1.references }
        default: return []
        }
    }

    func renumbered(_ map: (Int) -> Int?) -> PDFAValue {
        switch self {
        case .ref(let number):
            if let new = map(number) { return .ref(new) }
            return .null
        case .array(let items): return .array(items.map { $0.renumbered(map) })
        case .dict(let dict):
            var copy = dict
            copy.entries = dict.entries.map { ($0.0, $0.1.renumbered(map)) }
            return .dict(copy)
        default: return self
        }
    }

    /// Every Separation or DeviceN colour space array held in this value.
    var spotSpaces: [[PDFAValue]] {
        switch self {
        case .array(let items):
            let declares = items.first?.nameValue == "Separation" || items.first?.nameValue == "DeviceN"
            return (declares ? [items] : []) + items.flatMap { $0.spotSpaces }
        case .dict(let dict): return dict.entries.flatMap { $0.1.spotSpaces }
        default: return []
        }
    }

    /// Names to test against the forbidden list: keys and values, minus names that belong to someone else's vocabulary:
    /// glyphs, fonts, spot colorants, and blend modes (`/Screen`, checked on its own). `/TR` is only forbidden in graphics states.
    var checkedNames: [String] {
        switch self {
        case .name(let name): return [name]
        case .array(let items):
            if items.first?.nameValue == "Separation" || items.first?.nameValue == "DeviceN" {
                return items.enumerated().flatMap { $0.offset == 1 ? [] : $0.element.checkedNames }
            }
            return items.flatMap { $0.checkedNames }
        case .dict(let dict):
            let softMask = dict["G"] != nil && ["Alpha", "Luminosity"].contains(dict["S"]?.nameValue ?? "")
            return dict.entries.flatMap { key, value -> [String] in
                if key == "TR", softMask { return [] }
                if key == "Differences" || key == "BM" { return [key] }
                if key == "BaseFont" || key == "FontName" || key == "FontFamily" { return [key] }
                if key == "Colorants", case .dict(let colorants) = value { return [key] + colorants.entries.flatMap { $0.1.checkedNames } }
                return [key] + value.checkedNames
            }
        default: return []
        }
    }

    var serialized: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .real(let text): return text
        case .string(let bytes):
            if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                var out = "("
                for byte in bytes {
                    if byte == 0x28 || byte == 0x29 || byte == 0x5C { out += "\\" }
                    out.unicodeScalars.append(UnicodeScalar(byte))
                }
                return out + ")"
            }
            return "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
        case .name(let name): return "/" + PDFAValue.escapedName(name)
        case .array(let items): return "[ " + items.map { $0.serialized }.joined(separator: " ") + " ]"
        case .dict(let dict): return "<< " + dict.entries.map { "/\(PDFAValue.escapedName($0.0)) \($0.1.serialized)" }.joined(separator: " ") + " >>"
        case .ref(let number): return "\(number) 0 R"
        }
    }

    private static func escapedName(_ name: String) -> String {
        var out = ""
        for byte in name.utf8 {
            let delimiter = [0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25, 0x23].contains(byte)
            if byte <= 0x20 || byte >= 0x7F || delimiter {
                out += String(format: "#%02X", byte)
            } else {
                out.unicodeScalars.append(UnicodeScalar(byte))
            }
        }
        return out
    }
}

struct PDFAObject {
    var value: PDFAValue
    var streamStart: Int?
    var streamLength: Int?
    /// Bytes of a stream created by the rewrite.
    var inlineStream: [UInt8]?

    init(value: PDFAValue, streamStart: Int? = nil, inlineStream: [UInt8]? = nil) {
        self.value = value
        self.streamStart = streamStart
        self.inlineStream = inlineStream
    }

    var hasStream: Bool { streamStart != nil || inlineStream != nil }
}

/// Reads a classic-xref PDF byte by byte. Rejects anything else, so a rewrite never starts from a file it does not understand.
struct PDFAFile {
    enum ParseError: Error { case malformed }

    struct ContentStream {
        var number: Int
        /// The dictionary whose /Resources applies, nil for a page's own content.
        var resourceOwner: Int?
        var page: Int?
    }

    let bytes: [UInt8]
    var objects: [Int: PDFAObject] = [:]
    var trailer = PDFADict()

    init(parsing bytes: [UInt8], strict: Bool = false) throws {
        self.bytes = bytes
        var parser = PDFAParser(bytes)
        // startxref is the last keyword of the file.
        guard let keyword = parser.lastIndex(of: "startxref") else { throw ParseError.malformed }
        parser.position = keyword + 9
        guard case .int(let start) = try parser.value() else { throw ParseError.malformed }
        parser.position = start
        guard parser.consume("xref") else { throw ParseError.malformed }
        guard case .int(let first) = try parser.value(), first == 0, case .int(let count) = try parser.value(), count > 0 else { throw ParseError.malformed }
        var offsets: [Int: Int] = [:]
        if strict {
            // One table of 20-byte entries, directly after a single EOL, and directly before the trailer.
            parser.skipSpace()
            let table = parser.position
            let header = Array("xref\n0 \(count)\n".utf8)
            let end = table + count * 20
            guard table == start + header.count, Array(bytes[start..<table]) == header, end + 8 <= bytes.count,
                  Array(bytes[end..<(end + 8)]) == Array("trailer\n".utf8) else { throw ParseError.malformed }
        }
        for number in 0..<count {
            guard case .int(let offset) = try parser.value(), case .int = try parser.value() else { throw ParseError.malformed }
            parser.skipSpace()
            guard parser.position < bytes.count else { throw ParseError.malformed }
            let kind = bytes[parser.position]
            parser.position += 1
            if kind == 0x6E, offset != 0 { offsets[number] = offset } else if kind != 0x66 && kind != 0x6E { throw ParseError.malformed }
            if strict, number != 0, kind != 0x6E { throw ParseError.malformed }
            if strict, kind == 0x6E {
                let expected = Array("\(number) 0 obj\n".utf8)
                guard offset + expected.count <= bytes.count, Array(bytes[offset..<(offset + expected.count)]) == expected else { throw ParseError.malformed }
            }
        }
        guard parser.consume("trailer"), case .dict(let trailer) = try parser.value() else { throw ParseError.malformed }
        for key in ["Prev", "XRefStm", "Encrypt"] where trailer[key] != nil { throw ParseError.malformed }
        guard case .int(let size)? = trailer["Size"], size == count else { throw ParseError.malformed }
        self.trailer = trailer
        for (number, offset) in offsets {
            parser.position = offset
            guard case .int(let found) = try parser.value(), found == number, case .int(0) = try parser.value(), parser.consume("obj") else { throw ParseError.malformed }
            let value = try parser.value()
            parser.skipSpace()
            if parser.matches("stream") {
                guard case .dict = value else { throw ParseError.malformed }
                parser.position += 6
                if parser.peek == 0x0D { parser.position += 1 }
                guard parser.peek == 0x0A else { throw ParseError.malformed }
                parser.position += 1
                objects[number] = PDFAObject(value: value, streamStart: parser.position)
            } else {
                guard parser.consume("endobj") else { throw ParseError.malformed }
                objects[number] = PDFAObject(value: value)
            }
        }
        // Stream lengths may be references to objects that come later.
        for (number, object) in objects {
            guard let start = object.streamStart, let dict = object.value.dictValue,
                  case .int(let length)? = resolve(dict["Length"]), length >= 0, start + length <= bytes.count else {
                if objects[number]?.streamStart == nil { continue }
                throw ParseError.malformed
            }
            parser.position = start + length
            guard parser.consume("endstream"), parser.consume("endobj") else { throw ParseError.malformed }
            objects[number]?.streamLength = length
        }
    }

    func resolve(_ value: PDFAValue?) -> PDFAValue? {
        var current = value
        var hops = 0
        while case .ref(let number)? = current, hops < 32 {
            current = objects[number]?.value
            hops += 1
        }
        if case .ref? = current { return nil }
        return current
    }

    func dict(_ value: PDFAValue?) -> PDFADict? { resolve(value)?.dictValue }

    func isStream(_ value: PDFAValue?) -> Bool {
        guard let number = value?.referenceNumber else { return false }
        return objects[number]?.hasStream == true
    }

    func rawStream(_ number: Int) -> [UInt8]? {
        guard let object = objects[number] else { return nil }
        if let inline = object.inlineStream { return inline }
        guard let start = object.streamStart, let length = object.streamLength else { return nil }
        return Array(bytes[start..<(start + length)])
    }

    /// Stream bytes after a single FlateDecode, or as stored when there is no filter.
    func decodedStream(_ number: Int) -> [UInt8]? {
        guard let object = objects[number], let raw = rawStream(number), let dict = object.value.dictValue else { return nil }
        guard let filter = resolve(dict["Filter"]) else { return raw }
        if dict["DecodeParms"] != nil { return nil }
        switch filter {
        case .name("FlateDecode"): return PDFAFile.inflate(raw)
        case .array(let items) where items.count == 1 && resolve(items[0])?.nameValue == "FlateDecode": return PDFAFile.inflate(raw)
        default: return nil
        }
    }

    static func inflate(_ input: [UInt8]) -> [UInt8]? {
        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var input = input
        return input.withUnsafeMutableBufferPointer { source -> [UInt8]? in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress
                    stream.avail_out = uInt(target.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                output.append(contentsOf: buffer[0..<produced])
                if status == Z_STREAM_END { return output }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { return nil }
            }
        }
    }

    /// Page objects in document order.
    func pageNumbers(root: Int) throws -> [Int] {
        guard let catalog = dict(.ref(root)), let pagesRoot = catalog["Pages"]?.referenceNumber else { throw ParseError.malformed }
        var pages: [Int] = []
        var visited = Set<Int>()
        func walk(_ number: Int) throws {
            guard visited.insert(number).inserted, let node = objects[number]?.value.dictValue else { throw ParseError.malformed }
            switch resolve(node["Type"])?.nameValue {
            case "Pages":
                guard case .array(let kids)? = resolve(node["Kids"]) else { throw ParseError.malformed }
                for kid in kids {
                    guard let child = kid.referenceNumber else { throw ParseError.malformed }
                    try walk(child)
                }
            case "Page": pages.append(number)
            default: throw ParseError.malformed
            }
        }
        try walk(pagesRoot)
        return pages
    }

    /// Every stream that holds PDF drawing operators, with the object whose resources it runs under.
    func contentStreams(pages: [Int]) throws -> [ContentStream] {
        var result: [ContentStream] = []
        for page in pages {
            guard let dict = objects[page]?.value.dictValue else { continue }
            let references: [PDFAValue]
            switch dict["Contents"] ?? .null {
            case .ref(let number):
                if case .array(let items)? = objects[number]?.value { references = items } else { references = [.ref(number)] }
            case .array(let items): references = items
            case .null: references = []
            default: throw ParseError.malformed
            }
            for reference in references {
                guard let number = reference.referenceNumber, objects[number]?.hasStream == true else { throw ParseError.malformed }
                result.append(ContentStream(number: number, resourceOwner: nil, page: page))
            }
        }
        for (number, object) in objects {
            guard let dict = object.value.dictValue else { continue }
            if object.hasStream, resolve(dict["Subtype"])?.nameValue == "Form" || resolve(dict["PatternType"])?.numberValue == 1 {
                result.append(ContentStream(number: number, resourceOwner: number, page: nil))
            }
            if resolve(dict["Type"])?.nameValue == "Font", resolve(dict["Subtype"])?.nameValue == "Type3", let procs = self.dict(dict["CharProcs"]) {
                for proc in procs.entries {
                    guard let glyph = proc.1.referenceNumber, objects[glyph]?.hasStream == true else { throw ParseError.malformed }
                    result.append(ContentStream(number: glyph, resourceOwner: number, page: nil))
                }
            }
        }
        return result
    }

    /// An object's /Resources value, inherited through /Parent for pages.
    func inheritedResources(_ number: Int) -> PDFAValue? {
        var current = objects[number]?.value.dictValue
        var hops = 0
        while let dict = current, hops < 64 {
            if let resources = dict["Resources"] { return resources }
            guard let parent = dict["Parent"]?.referenceNumber else { return nil }
            current = objects[parent]?.value.dictValue
            hops += 1
        }
        return nil
    }

    mutating func setDefaultCMYK(in resources: inout PDFADict, to arrayNumber: Int) {
        switch resources["ColorSpace"] {
        case .ref(let number)?:
            // Shapes other than a dictionary are rejected by the final check.
            if var shared = objects[number]?.value.dictValue {
                shared["DefaultCMYK"] = .ref(arrayNumber)
                objects[number]?.value = .dict(shared)
            }
        case .dict(var spaces)?:
            spaces["DefaultCMYK"] = .ref(arrayNumber)
            resources["ColorSpace"] = .dict(spaces)
        default:
            var spaces = PDFADict()
            spaces["DefaultCMYK"] = .ref(arrayNumber)
            resources["ColorSpace"] = .dict(spaces)
        }
    }

}

/// Byte-level parser for the PDF object grammar.
struct PDFAParser {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var peek: UInt8? { position < bytes.count ? bytes[position] : nil }

    static func isSpace(_ byte: UInt8) -> Bool { byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32 }
    static func isDelimiter(_ byte: UInt8) -> Bool { [0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25].contains(byte) }

    mutating func skipSpace() {
        while let byte = peek {
            if PDFAParser.isSpace(byte) { position += 1 } else if byte == 0x25 {
                while let inner = peek, inner != 10, inner != 13 { position += 1 }
            } else { break }
        }
    }

    func lastIndex(of keyword: String) -> Int? {
        let target = Array(keyword.utf8)
        var index = bytes.count - target.count
        while index >= 0 {
            if bytes[index] == target[0], Array(bytes[index..<(index + target.count)]) == target { return index }
            index -= 1
        }
        return nil
    }

    func matches(_ keyword: String) -> Bool {
        let target = Array(keyword.utf8)
        return position + target.count <= bytes.count && Array(bytes[position..<(position + target.count)]) == target
    }

    mutating func consume(_ keyword: String) -> Bool {
        skipSpace()
        guard matches(keyword) else { return false }
        position += keyword.utf8.count
        return true
    }

    mutating func value(depth: Int = 0) throws -> PDFAValue {
        guard depth < 64 else { throw PDFAFile.ParseError.malformed }
        skipSpace()
        guard let byte = peek else { throw PDFAFile.ParseError.malformed }
        switch byte {
        case 0x2F: return .name(try name())
        case 0x28: return .string(try literal())
        case 0x5B:
            position += 1
            var items: [PDFAValue] = []
            while true {
                skipSpace()
                if peek == 0x5D { position += 1; return .array(items) }
                items.append(try value(depth: depth + 1))
            }
        case 0x3C:
            if position + 1 < bytes.count, bytes[position + 1] == 0x3C {
                position += 2
                var dict = PDFADict()
                while true {
                    skipSpace()
                    if matches(">>") { position += 2; return .dict(dict) }
                    guard peek == 0x2F else { throw PDFAFile.ParseError.malformed }
                    let key = try name()
                    dict[key] = try value(depth: depth + 1)
                }
            }
            return .string(try hexString())
        default:
            if (0x30...0x39).contains(byte) || byte == 0x2B || byte == 0x2D || byte == 0x2E { return try number() }
            if consumeWord("true") { return .bool(true) }
            if consumeWord("false") { return .bool(false) }
            if consumeWord("null") { return .null }
            throw PDFAFile.ParseError.malformed
        }
    }

    private mutating func consumeWord(_ word: String) -> Bool {
        guard matches(word) else { return false }
        let end = position + word.utf8.count
        if end < bytes.count, !PDFAParser.isSpace(bytes[end]), !PDFAParser.isDelimiter(bytes[end]) { return false }
        position = end
        return true
    }

    private mutating func regularToken() -> [UInt8] {
        let start = position
        while let byte = peek, !PDFAParser.isSpace(byte), !PDFAParser.isDelimiter(byte) { position += 1 }
        return Array(bytes[start..<position])
    }

    private mutating func number() throws -> PDFAValue {
        let token = regularToken()
        guard let text = String(bytes: token, encoding: .ascii), !text.isEmpty else { throw PDFAFile.ParseError.malformed }
        if let integer = Int(text) {
            // `n g R` needs a look ahead past the next two tokens.
            if integer >= 0, !text.hasPrefix("+") {
                let saved = position
                skipSpace()
                let second = regularToken()
                if let generation = String(bytes: second, encoding: .ascii).flatMap(Int.init), generation >= 0 {
                    skipSpace()
                    if peek == 0x52 {
                        let after = position + 1
                        if after == bytes.count || PDFAParser.isSpace(bytes[after]) || PDFAParser.isDelimiter(bytes[after]) {
                            position = after
                            return .ref(integer)
                        }
                    }
                }
                position = saved
            }
            return .int(integer)
        }
        guard text.contains("."), Double(text) != nil else { throw PDFAFile.ParseError.malformed }
        return .real(text)
    }

    private mutating func name() throws -> String {
        position += 1
        var decoded: [UInt8] = []
        let token = regularToken()
        var index = 0
        while index < token.count {
            if token[index] == 0x23 {
                guard index + 2 < token.count, let high = PDFAParser.hexDigit(token[index + 1]), let low = PDFAParser.hexDigit(token[index + 2]) else { throw PDFAFile.ParseError.malformed }
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(token[index])
                index += 1
            }
        }
        guard let name = String(bytes: decoded, encoding: .utf8) else { throw PDFAFile.ParseError.malformed }
        return name
    }

    static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private mutating func hexString() throws -> [UInt8] {
        position += 1
        var digits: [UInt8] = []
        while let byte = peek, byte != 0x3E {
            position += 1
            if PDFAParser.isSpace(byte) { continue }
            guard let digit = PDFAParser.hexDigit(byte) else { throw PDFAFile.ParseError.malformed }
            digits.append(digit)
        }
        guard peek == 0x3E, digits.count % 2 == 0 else { throw PDFAFile.ParseError.malformed }
        position += 1
        return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
    }

    private mutating func literal() throws -> [UInt8] {
        position += 1
        var depth = 1
        var out: [UInt8] = []
        while let byte = peek {
            position += 1
            switch byte {
            case 0x28: depth += 1; out.append(byte)
            case 0x29:
                depth -= 1
                if depth == 0 { return out }
                out.append(byte)
            case 0x5C:
                guard let next = peek else { throw PDFAFile.ParseError.malformed }
                position += 1
                switch next {
                case 0x6E: out.append(10)
                case 0x72: out.append(13)
                case 0x74: out.append(9)
                case 0x62: out.append(8)
                case 0x66: out.append(12)
                case 0x0D: if peek == 0x0A { position += 1 }
                case 0x0A: break
                case 0x30...0x37:
                    var octal = Int(next - 0x30)
                    var count = 1
                    while count < 3, let digit = peek, (0x30...0x37).contains(digit) {
                        octal = octal * 8 + Int(digit - 0x30)
                        position += 1
                        count += 1
                    }
                    out.append(UInt8(octal & 0xFF))
                default: out.append(next)
                }
            case 0x0D:
                if peek == 0x0A { position += 1 }
                out.append(10)
            default: out.append(byte)
            }
        }
        throw PDFAFile.ParseError.malformed
    }
}

/// What the rewrite and the final check need to know about a content stream.
struct PDFAContentScan {
    private(set) var usesCMYK = false
    private(set) var maxDepth = 0
    private(set) var badInlineImage = false
    private(set) var badRenderingIntent = false
    private(set) var hasLongString = false
    private(set) var showsNotdef = false

    static let intents: Set<String> = ["RelativeColorimetric", "AbsoluteColorimetric", "Perceptual", "Saturation"]

    /// `identityFonts` are the resource names of fonts in which a two-byte code of 0 is `.notdef`.
    init(_ bytes: [UInt8], identityFonts: Set<String> = []) {
        var font = ""
        var savedFonts: [String] = []
        var pendingNotdef = false
        var parser = PDFAParser(bytes)
        var index = 0
        var depth = 0
        var lastName = ""
        var inInlineDict = false
        var lastKey = ""
        func word(from start: Int) -> (String, Int) {
            var end = start
            while end < bytes.count, !PDFAParser.isSpace(bytes[end]), !PDFAParser.isDelimiter(bytes[end]) { end += 1 }
            return (String(decoding: bytes[start..<end], as: UTF8.self), end)
        }
        func inspect(_ text: [UInt8]) -> (long: Bool, notdef: Bool) {
            let notdef = identityFonts.contains(font) && stride(from: 0, to: text.count - 1, by: 2).contains { text[$0] == 0 && text[$0 + 1] == 0 }
            return (text.count > 32767, notdef)
        }
        while index < bytes.count {
            let byte = bytes[index]
            if PDFAParser.isSpace(byte) { index += 1; continue }
            switch byte {
            case 0x25:
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
            case 0x28:
                parser.position = index
                guard case .string(let text)? = try? parser.value() else { index = bytes.count; break }
                index = parser.position
                let found = inspect(text)
                if found.long { hasLongString = true }
                if found.notdef { pendingNotdef = true }
            case 0x3C:
                if index + 1 < bytes.count, bytes[index + 1] == 0x3C { index += 2 } else {
                    parser.position = index
                    if case .string(let text)? = try? parser.value() {
                        index = parser.position
                        let found = inspect(text)
                        if found.long { hasLongString = true }
                        if found.notdef { pendingNotdef = true }
                    } else {
                        while index < bytes.count, bytes[index] != 0x3E { index += 1 }
                        index += 1
                    }
                }
            case 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x29:
                index += 1
            case 0x2F:
                let (name, end) = word(from: index + 1)
                lastName = name
                index = end
                if inInlineDict {
                    if name == "LZW" || name == "LZWDecode" || name == "Crypt" { badInlineImage = true }
                    if name == "CMYK" || name == "DeviceCMYK" { usesCMYK = true }
                    lastKey = name
                }
            default:
                let (token, end) = word(from: index)
                index = end > index ? end : index + 1
                if inInlineDict {
                    if token == "true", lastKey == "I" || lastKey == "Interpolate" { badInlineImage = true }
                    if token == "ID" {
                        inInlineDict = false
                        index += 1
                        // Skip to EI on its own between whitespace.
                        while index + 1 < bytes.count {
                            if bytes[index] == 0x45, bytes[index + 1] == 0x49,
                               index == 0 || PDFAParser.isSpace(bytes[index - 1]),
                               index + 2 >= bytes.count || PDFAParser.isSpace(bytes[index + 2]) { break }
                            index += 1
                        }
                        index += 2
                    }
                    continue
                }
                // Numbers are TJ spacing; anything else ends the operands.
                if let first = token.utf8.first, !(0x2B...0x39).contains(first) {
                    if pendingNotdef, ["Tj", "TJ", "'", "\""].contains(token) { showsNotdef = true }
                    pendingNotdef = false
                }
                switch token {
                case "q":
                    depth += 1
                    maxDepth = max(maxDepth, depth)
                    savedFonts.append(font)
                case "Q":
                    depth = max(0, depth - 1)
                    font = savedFonts.popLast() ?? font
                case "Tf": font = lastName
                case "k", "K": usesCMYK = true
                case "cs", "CS": if lastName == "DeviceCMYK" { usesCMYK = true }
                case "ri": if !PDFAContentScan.intents.contains(lastName) { badRenderingIntent = true }
                case "BI": inInlineDict = true
                default: break
                }
            }
        }
    }
}
