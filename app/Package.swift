// swift-tools-version:5.9
// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "Verbalog",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Verbalog", targets: ["VerbalogApp"]),
        .executable(name: "verbalog-capture", targets: ["verbalog-capture"]),
    ],
    targets: [
        .target(name: "VerbalogCaptureKit"),
        .target(name: "VerbalogCore"),
        .executableTarget(name: "verbalog-capture", dependencies: ["VerbalogCaptureKit"]),
        .executableTarget(name: "VerbalogApp", dependencies: ["VerbalogCaptureKit", "VerbalogCore"]),
        .testTarget(name: "VerbalogCoreTests", dependencies: ["VerbalogCaptureKit", "VerbalogCore"]),
    ]
)
