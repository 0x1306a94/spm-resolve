// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "spm-resolve",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-package-manager.git", revision: "88d5888f7f74b979f36aac41b4972aed58936fa2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .target(name: "DepctlDEPS"),
        .target(
            name: "PackageRewrite",
            dependencies: [
                "DepctlDEPS",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "spm-resolve",
            dependencies: [
                "DepctlDEPS",
                "PackageRewrite",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftPMDataModel-auto", package: "swift-package-manager"),
            ]
        ),
        .testTarget(
            name: "DepctlDEPSTests",
            dependencies: ["DepctlDEPS"]
        ),
        .testTarget(
            name: "PackageRewriteTests",
            dependencies: ["PackageRewrite"]
        ),
    ]
)
