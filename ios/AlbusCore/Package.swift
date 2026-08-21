// swift-tools-version: 6.0
import PackageDescription

// The app's logic lives here rather than in the Xcode target so it can be
// built and tested with `swift test` — no simulator, no project file, no UI.
// The scheduler in particular is the highest-risk code in the product and the
// easiest to get wrong quietly, so it is kept where it can be hammered.
let package = Package(
    name: "AlbusCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "AlbusCore", targets: ["AlbusCore"])
    ],
    targets: [
        .target(name: "AlbusCore"),
        .testTarget(name: "AlbusCoreTests", dependencies: ["AlbusCore"])
    ]
)
