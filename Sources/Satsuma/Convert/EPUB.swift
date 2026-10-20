import Foundation

/// Builds EPUB 3 packages. The `mimetype` entry is first and uncompressed, as the original enforces.
enum EPUBWriter {
    static let css = "body{font:12pt Arial,sans-serif;line-height:1.35;margin:2em;color:#000}h1,h2,h3,h4,h5,h6{break-after:avoid}p{orphans:2;widows:2}table{border-collapse:collapse;max-width:100%;table-layout:fixed}td,th{border:1px solid #aaa;padding:0.4em;vertical-align:top;overflow-wrap:break-word}th{background:#eee}img{max-width:100%;height:auto}header,footer{font-size:0.9em}section{break-before:page}section:first-child{break-before:auto}"

    struct Chapter {
        var title: String
        var bodyHTML: String
        var anchors: [(id: String, label: String, level: Int)] = []
    }

    struct Asset {
        var path: String      // relative to OEBPS, e.g. images/p1.png
        var mediaType: String
        var data: Data
    }

    static func write(title: String, bodyHTML: String, to url: URL) throws {
        try write(title: title, chapters: [Chapter(title: title, bodyHTML: bodyHTML)], assets: [], to: url)
    }

    static func write(title: String, chapters: [Chapter], assets: [Asset], fixedLayout: Bool = false,
                      pageSize: CGSize? = nil, to url: URL) throws {
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip")
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        let identifier = "urn:uuid:\(UUID().uuidString)"
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        var manifest = [
            "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
            "<item id=\"style\" href=\"style.css\" media-type=\"text/css\"/>",
        ]
        var spine: [String] = []
        var navItems: [String] = []
        for (index, chapter) in chapters.enumerated() {
            let name = "chapter-\(index + 1).xhtml"
            manifest.append("<item id=\"c\(index + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>")
            spine.append("<itemref idref=\"c\(index + 1)\"/>")
            var viewport = ""
            if fixedLayout, let pageSize { viewport = "<meta name=\"viewport\" content=\"width=\(Int(pageSize.width)),height=\(Int(pageSize.height))\"/>" }
            zip.add("OEBPS/\(name)", """
            <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><meta charset="utf-8"/>\(viewport)<title>\(chapter.title.xmlEscaped)</title><link rel="stylesheet" href="style.css"/></head><body>\(chapter.bodyHTML)</body></html>
            """)
            if chapter.anchors.isEmpty {
                navItems.append("<li><a href=\"\(name)\">\(chapter.title.xmlEscaped)</a></li>")
            } else {
                for anchor in chapter.anchors where anchor.level <= 2 {
                    navItems.append("<li><a href=\"\(name)#\(anchor.id)\">\(anchor.label.xmlEscaped)</a></li>")
                }
            }
        }
        for (index, asset) in assets.enumerated() {
            manifest.append("<item id=\"a\(index + 1)\" href=\"\(asset.path)\" media-type=\"\(asset.mediaType)\"/>")
            zip.add("OEBPS/\(asset.path)", asset.data)
        }
        zip.add("OEBPS/style.css", css)
        zip.add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>\(navItems.joined())</ol></nav></body></html>
        """)
        let layout = fixedLayout ? "<meta property=\"rendition:layout\">pre-paginated</meta>" : "<meta property=\"rendition:layout\">reflowable</meta>"
        zip.add("OEBPS/package.opf", """
        <?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">\(identifier)</dc:identifier><dc:title>\(title.xmlEscaped)</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">\(modified)</meta>\(layout)</metadata><manifest>\(manifest.joined())</manifest><spine>\(spine.joined())</spine></package>
        """)
        try zip.finish().write(to: url)
    }
}

/// Reads an EPUB into a single HTML document (spine order).
enum EPUBReader {
    static func html(from url: URL) throws -> String {
        let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-epub-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw ConversionError.encodingFailed("The EPUB ZIP container is damaged or unsupported.") }

        let container = try XMLDocument(contentsOf: folder.appendingPathComponent("META-INF/container.xml"), options: [])
        guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw ConversionError.encodingFailed("The EPUB does not identify a readable package document.")
        }
        let opfURL = folder.appendingPathComponent(opfPath)
        let opf = try XMLDocument(contentsOf: opfURL, options: [])
        var manifest: [String: String] = [:]
        for item in try opf.nodes(forXPath: "//*[local-name()='item']") {
            guard let element = item as? XMLElement, let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = href
        }
        let base = opfURL.deletingLastPathComponent()
        var bodies: [String] = []
        for ref in try opf.nodes(forXPath: "//*[local-name()='itemref']/@idref") {
            guard let id = ref.stringValue, let href = manifest[id]?.removingPercentEncoding else { continue }
            let chapterURL = base.appendingPathComponent(href)
            guard let chapter = try? XMLDocument(contentsOf: chapterURL, options: [.documentTidyHTML]),
                  let body = try chapter.nodes(forXPath: "//*[local-name()='body']").first as? XMLElement else { continue }
            // Inline images as data URLs so NSAttributedString can load them.
            for node in try body.nodes(forXPath: ".//*[local-name()='img']") {
                guard let img = node as? XMLElement, let src = img.attribute(forName: "src")?.stringValue,
                      let data = try? Data(contentsOf: chapterURL.deletingLastPathComponent().appendingPathComponent(src)) else { continue }
                img.attribute(forName: "src")?.stringValue = "data:image/\(src.hasSuffix(".png") ? "png" : "jpeg");base64,\(data.base64EncodedString())"
            }
            bodies.append((body.children ?? []).map { $0.xmlString }.joined())
        }
        guard !bodies.isEmpty else { throw ConversionError.encodingFailed("The EPUB has no readable chapters.") }
        return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(bodies.joined(separator: "<hr/>"))</body></html>"
    }
}
