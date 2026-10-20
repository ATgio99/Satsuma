// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Satsuma",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Satsuma",
            path: "Sources/Satsuma",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedLibrary("z"),
            ]
        ),
        .testTarget(
            name: "SatsumaTests",
            dependencies: ["Satsuma"],
            path: "Tests/SatsumaTests"
        ),
    ]
)
