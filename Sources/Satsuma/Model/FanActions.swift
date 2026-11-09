import Foundation

/// Which wheel is open (`ConversionFanMode`).
enum ConversionFanMode: Int, Codable, CaseIterable {
    case conversions, fileTools, fileActions

    var title: String {
        switch self {
        case .conversions: return "Conversion wheel"
        case .fileTools: return "Tools wheel"
        case .fileActions: return "Actions wheel"
        }
    }
}

/// The 29 file tools, in the binary's enum order (`FileTool`).
enum FileTool: Int, CaseIterable, Codable, Hashable {
    case compress, removeMetadata, editImage, annotateImage, frameImage, cropImage, resizeImage
    case normalizeAudio, muteVideo, trimVideo, splitPDF, organizePDF, convertPDFA, extractArchive
    case createPDF, mergePDF, cropVideo, changeVideoSpeed, joinVideos, videoSnapshots
    case splitVideo, audioToVideo, trimAudio, audioChannels, createCollage, readQRCode
    case redactImage, redactVideo, redactAudio

    /// Petal title, window name and SF Symbol, as published by the original app.
    var title: String {
        switch self {
        case .compress: return "COMPRESS"
        case .removeMetadata: return "METADATA"
        case .editImage: return "EDIT"
        case .annotateImage: return "ANNOTATE"
        case .frameImage: return "ADD BG"
        case .cropImage: return "CROP"
        case .resizeImage: return "RESIZE"
        case .normalizeAudio: return "NORMALIZE"
        case .muteVideo: return "MUTE"
        case .trimVideo: return "TRIM"
        case .splitPDF: return "SPLIT"
        case .organizePDF: return "ORGANIZE"
        case .convertPDFA: return "PDF/A-2B"
        case .extractArchive: return "EXTRACT"
        case .createPDF: return "CREATE PDF"
        case .mergePDF: return "MERGE PDF"
        case .cropVideo: return "CROP"
        case .changeVideoSpeed: return "SPEED"
        case .joinVideos: return "JOIN"
        case .videoSnapshots: return "SNAPSHOT"
        case .splitVideo: return "SPLIT"
        case .audioToVideo: return "VISUALIZE"
        case .trimAudio: return "TRIM"
        case .audioChannels: return "CHANNELS"
        case .createCollage: return "COLLAGE"
        case .readQRCode: return "QR CODE"
        case .redactImage: return "REDACT"
        case .redactVideo: return "REDACT"
        case .redactAudio: return "BLEEP"
        }
    }
    var name: String {
        switch self {
        case .compress: return "Compress"
        case .removeMetadata: return "Metadata"
        case .editImage: return "Edit Photo"
        case .annotateImage: return "Annotate Photo"
        case .frameImage: return "Add BG"
        case .cropImage: return "Crop Image"
        case .resizeImage: return "Resize Images"
        case .normalizeAudio: return "Normalize Volume"
        case .muteVideo: return "Remove Audio"
        case .trimVideo: return "Trim Video"
        case .splitPDF: return "Split PDF"
        case .organizePDF: return "Organize PDF"
        case .convertPDFA: return "Convert to PDF/A-2b"
        case .extractArchive: return "Extract Archive"
        case .createPDF: return "Create PDF"
        case .mergePDF: return "Merge PDFs"
        case .cropVideo: return "Crop Video"
        case .changeVideoSpeed: return "Change Video Speed"
        case .joinVideos: return "Join Videos"
        case .videoSnapshots: return "Video Snapshots"
        case .splitVideo: return "Split Video"
        case .audioToVideo: return "Audio Visualizer"
        case .trimAudio: return "Trim Audio"
        case .audioChannels: return "Convert Audio Channels"
        case .createCollage: return "Create Collage"
        case .readQRCode: return "Read QR Codes"
        case .redactImage: return "Redact Photo"
        case .redactVideo: return "Redact Video"
        case .redactAudio: return "Bleep Audio"
        }
    }
    var symbolName: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: return "tag"
        case .editImage: return "slider.horizontal.3"
        case .annotateImage: return "pencil.and.outline"
        case .frameImage: return "photo.artframe"
        case .cropImage: return "crop"
        case .resizeImage: return "arrow.up.left.and.arrow.down.right"
        case .normalizeAudio: return "waveform"
        case .muteVideo: return "speaker.slash.fill"
        case .trimVideo: return "scissors"
        case .splitPDF: return "rectangle.split.2x1"
        case .organizePDF: return "square.grid.2x2"
        case .convertPDFA: return "checkmark.seal"
        case .extractArchive: return "archivebox"
        case .createPDF: return "doc.badge.plus"
        case .mergePDF: return "doc.on.doc"
        case .cropVideo: return "crop"
        case .changeVideoSpeed: return "speedometer"
        case .joinVideos: return "film.stack"
        case .videoSnapshots: return "camera"
        case .splitVideo: return "film"
        case .audioToVideo: return "waveform"
        case .trimAudio: return "scissors"
        case .audioChannels: return "hifispeaker.2"
        case .createCollage: return "rectangle.3.group"
        case .readQRCode: return "qrcode.viewfinder"
        case .redactImage: return "eye.slash"
        case .redactVideo: return "eye.slash"
        case .redactAudio: return "waveform.badge.minus"
        }
    }

    /// Tools that open an options window first (the original app's set `Qe`); the rest run straight away.
    var opensOptionsWindow: Bool {
        ![.muteVideo, .splitPDF, .convertPDFA, .extractArchive, .createPDF, .readQRCode].contains(self)
    }
}

/// One petal of a wheel (`ConversionFanAction`).
enum ConversionFanAction: Hashable {
    case convert(ConversionFormat)
    case fileTool(FileTool)
    case airDrop, float, copy, move, copyPath, openTerminal

    static let fileActions: [ConversionFanAction] = [.airDrop, .float, .copy, .move, .copyPath, .openTerminal]

    var title: String {
        switch self {
        case .convert(let format): return format.title
        case .fileTool(let tool): return tool.title
        case .airDrop: return "AIRDROP"
        case .float: return "FLOAT"
        case .copy: return "COPY"
        case .move: return "MOVE"
        case .copyPath: return "COPY PATH"
        case .openTerminal: return "TERMINAL"
        }
    }

    /// Non-conversion petals carry an SF Symbol above the label (tag >= 0x40 in the binary).
    var symbolName: String? {
        switch self {
        case .convert: return nil
        case .fileTool(let tool): return tool.symbolName
        case .airDrop: return "airplayaudio"
        case .float: return "pin.fill"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "doc.text"
        case .openTerminal: return "terminal"
        }
    }

    /// Text shown in the center capsule while the petal is highlighted.
    var centerTitle: String {
        switch self {
        case .convert(let format): return format.title
        case .fileTool(let tool): return tool.title
        default: return title
        }
    }

    /// Display name ("Convert to PNG", "Compress", "AirDrop").
    var name: String {
        switch self {
        case .convert(let format): return "Convert to \(format.title)"
        case .fileTool(let tool): return tool.name
        case .airDrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .openTerminal: return "Terminal"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .convert(let format): return "Convert to \(format.title)"
        case .fileTool(let tool): return tool.name
        case .airDrop: return "Share files and folders with AirDrop"
        case .float: return "Float file or folder thumbnail"
        case .copy: return "Copy files and folders"
        case .move: return "Move files and folders to a chosen folder"
        case .copyPath: return "Copy file and folder paths"
        case .openTerminal: return "Open terminal in folder"
        }
    }
}
