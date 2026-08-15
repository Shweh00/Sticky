// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FloatingTodo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FloatingTodo",
            path: "FloatingTodo",
            exclude: ["Assets.xcassets", "Resources"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        )
    ]
)
