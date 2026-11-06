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
        // Fixtures are read from the source tree; `web/packages/server/test/IosContract.test.ts` shares them.
        .testTarget(name: "CadenciaCoreTests", dependencies: ["CadenciaCore"], exclude: ["Fixtures"])
    ],
    swiftLanguageModes: [.v5]
)
