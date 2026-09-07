// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RecRec",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RecRecCore", path: "Sources/RecRecCore"),
        .executableTarget(name: "RecRec", dependencies: ["RecRecCore"], path: "Sources/RecRec"),
        .executableTarget(name: "RecRecTests", dependencies: ["RecRecCore"], path: "Sources/RecRecTests"),
    ]
)
