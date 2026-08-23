// swift-tools-version: 6.2
import PackageDescription
import Foundation

// 当系统仅安装 Command Line Tools（无 Xcode）时，XCTest 与 Testing 框架
// 不在默认搜索路径。此处检测 CLT 提供的 Testing.framework，若存在则显式
// 指定 framework 搜索路径 + Testing 宏插件库，使 `swift test` 可运行。
// 安装了 Xcode 的环境下 Testing / XCTest 可被自动发现，无需这些 flags。
private let cltFrameworksPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
private let cltTestingMacroPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
private let cltTestingAvailable: Bool = FileManager.default.fileExists(atPath: cltFrameworksPath + "/Testing.framework")

// Testing.framework 自身与它的依赖 lib_TestingInterop.dylib 的 install_name 都是
// @rpath/... 形式，需要把这些目录写入 test runner 的 rpath，运行时 dyld 才能定位：
//   - cltFrameworksPath            提供 Testing.framework
//   - cltTestingLibPath            提供 lib_TestingInterop.dylib
private let cltTestingLibPath = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

private let testingSwiftSettings: [SwiftSetting] = cltTestingAvailable ? [
    .unsafeFlags([
        "-F", cltFrameworksPath,
        "-load-plugin-library", cltTestingMacroPath,
    ]),
] : []

// 链接期与运行期需要同样的 framework 搜索路径：
//   -F                 让链接器在 cltFrameworksPath 下找到 Testing.framework
//   -framework Testing 显式链接 Testing.framework 二进制
//   -Xlinker -rpath ... 在生成的 test runner 中写入 rpath，使运行时 dyld
//                       也能定位 Testing.framework 及其依赖 lib_TestingInterop.dylib
private let testingLinkerSettings: [LinkerSetting] = cltTestingAvailable ? [
    .unsafeFlags([
        "-F", cltFrameworksPath,
        "-framework", "Testing",
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworksPath,
        "-Xlinker", "-rpath", "-Xlinker", cltTestingLibPath,
    ]),
] : []

let package = Package(
    name: "BatteryBar",
    platforms: [.macOS(.v14)],
    targets: [
        // App 与特权 Helper 共用的纯解析/归一化逻辑，保持协议两端口径一致并可单测。
        .target(
            name: "TelemetryCore",
            dependencies: [],
            path: "Sources/TelemetryCore"
        ),
        // 主应用
        .executableTarget(
            name: "BatteryBar",
            dependencies: ["TelemetryCore"],
            path: "Sources/BatteryBar",
            resources: [
                .copy("Resources/AppIcon.png"),
                .copy("Resources/AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts"),
                .linkedFramework("Security"),
                .linkedFramework("ImageIO"),
                .linkedLibrary("compression"),
            ]
        ),
        // Privileged Helper Tool
        .executableTarget(
            name: "BatteryBarHelper",
            dependencies: ["TelemetryCore"],
            path: "Sources/BatteryBarHelper"
        ),
        // 单元测试
        .testTarget(
            name: "BatteryBarTests",
            dependencies: ["BatteryBar", "TelemetryCore"],
            path: "Tests/BatteryBarTests",
            swiftSettings: testingSwiftSettings,
            linkerSettings: testingLinkerSettings
        ),
    ]
)
