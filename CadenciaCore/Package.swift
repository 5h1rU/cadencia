// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CadenciaCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CadenciaCore", targets: ["CadenciaCore"])
    ],
    targets: [
        .target(name: "CadenciaCore"),
        .testTarget(name: "CadenciaCoreTests", dependencies: ["CadenciaCore"])
    ],
    swiftLanguageModes: [.v5]
)
