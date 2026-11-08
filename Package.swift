// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YandexLoader",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "YandexLoader", targets: ["YandexLoader"])],
    targets: [
        .binaryTarget(name: "Sparkle", url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip", checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"),
        .executableTarget(name: "YandexLoader", dependencies: ["Sparkle"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("SceneKit"),
            .linkedFramework("ModelIO"), .linkedFramework("Quartz"),
            .linkedFramework("WebKit"), .linkedFramework("Security"),
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ])
    ]
)
