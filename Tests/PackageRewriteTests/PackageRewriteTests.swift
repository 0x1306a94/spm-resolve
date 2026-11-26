import Foundation
import Testing

@testable import PackageRewrite

@Test func rewriteReplacesURLAndKeepsComment() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let example = try fixture.package(named: "deps/Example", source: emptyPackage(name: "Example"))
    let app = try fixture.package(
        named: "Packages/App",
        source: """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                // .package(url: "https://github.com/example/Skip.git", from: "1.0.0"),
                .package(url: "https://github.com/example/Example.git", from: "1.2.3"),
                .package(path: "../Theme"),
            ]
        )

        """
    )
    try fixture.package(named: "Packages/Theme", source: emptyPackage(name: "Theme"))

    let plan = try PackageRewriter.plan(packageDirectory: app, directoryPrefix: fixture.url.appendingPathComponent("deps"))
    #expect(plan.missing.isEmpty)
    #expect(plan.edits.count == 1)
    let rewritten = try #require(plan.edits.first?.rewritten)
    #expect(rewritten.contains(".package(path: \"../../deps/Example\")"))
    #expect(rewritten.contains("// .package(url: \"https://github.com/example/Skip.git\", from: \"1.0.0\"),"))
    #expect(rewritten.contains(".package(path: \"../Theme\")"))
    #expect(!rewritten.contains("example/Example.git"))
    _ = example
}

@Test func rewriteFollowsPathAndUsesSiblingRelativePath() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let manager = try fixture.package(
        named: "third_party/Packages/IQKeyboardManager",
        source: """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "IQKeyboardManager",
            dependencies: [
                .package(url: "https://github.com/hackiftekhar/IQKeyboardNotification.git", from: "1.0.7"),
                .package(
                    url: "https://github.com/hackiftekhar/IQTextView.git",
                    .upToNextMajor(from: "1.0.5")
                ),
            ]
        )

        """
    )
    try fixture.package(named: "third_party/Packages/IQKeyboardNotification", source: emptyPackage(name: "IQKeyboardNotification"))
    try fixture.package(named: "third_party/Packages/IQTextView", source: emptyPackage(name: "IQTextView"))
    let app = try fixture.package(
        named: "Packages/App",
        source: """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(path: "../AppContext"),
                .package(url: "https://github.com/hackiftekhar/IQKeyboardManager.git", from: "8.0.3"),
                .package(id: "example.logger", from: "1.0.0"),
            ]
        )

        """
    )
    try fixture.package(
        named: "Packages/AppContext",
        source: """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "AppContext",
            dependencies: [
                .package(url: "https://github.com/hackiftekhar/IQTextInputViewNotification", from: "1.0.9"),
            ]
        )

        """
    )
    try fixture.package(
        named: "third_party/Packages/IQTextInputViewNotification",
        source: emptyPackage(name: "IQTextInputViewNotification")
    )

    let plan = try PackageRewriter.plan(
        packageDirectory: app,
        directoryPrefix: fixture.url.appendingPathComponent("third_party/Packages")
    )
    #expect(plan.missing.isEmpty)
    #expect(plan.skippedRegistries == ["example.logger"])
    let sources = Dictionary(uniqueKeysWithValues: plan.edits.map { ($0.manifestPath, $0.rewritten) })
    let managerSource = try #require(sources[manifestPath(manager)])
    #expect(managerSource.contains(".package(path: \"../IQKeyboardNotification\")"))
    #expect(managerSource.contains(".package(path: \"../IQTextView\")"))
    #expect(!managerSource.contains(".upToNextMajor"))
    let appSource = try #require(sources[manifestPath(app)])
    #expect(appSource.contains(".package(path: \"../../third_party/Packages/IQKeyboardManager\")"))
    #expect(appSource.contains(".package(path: \"../AppContext\")"))
    #expect(appSource.contains(".package(id: \"example.logger\", from: \"1.0.0\")"))
    let contextSource = try #require(sources[manifestPath(fixture.url.appendingPathComponent("Packages/AppContext"))])
    #expect(contextSource.contains(".package(path: \"../../third_party/Packages/IQTextInputViewNotification\")"))
}

@Test func rewriteUpdatesVersionSpecificManifests() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let lumberjack = try fixture.package(
        named: "third_party/Packages/CocoaLumberjack",
        source: """
        // swift-tools-version:6.1
        import PackageDescription
        let package = Package(
            name: "CocoaLumberjack",
            dependencies: [
                .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
            ]
        )

        """
    )
    let older = lumberjack.appendingPathComponent("Package@swift-6.0.swift")
    try """
    // swift-tools-version:6.0
    import PackageDescription
    let package = Package(
        name: "CocoaLumberjack",
        dependencies: [
            .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        ]
    )

    """.write(to: older, atomically: true, encoding: .utf8)
    try fixture.package(named: "third_party/Packages/swift-log", source: emptyPackage(name: "swift-log"))
    let app = try fixture.package(
        named: "Packages/App",
        source: """
        // swift-tools-version:6.1
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(path: "../../third_party/Packages/CocoaLumberjack"),
            ]
        )

        """
    )

    let plan = try PackageRewriter.plan(
        packageDirectory: app,
        directoryPrefix: fixture.url.appendingPathComponent("third_party/Packages")
    )
    let sources = Dictionary(uniqueKeysWithValues: plan.edits.map { ($0.manifestPath, $0.rewritten) })
    let current = try #require(sources[manifestPath(lumberjack)])
    let legacy = try #require(sources[older.standardizedFileURL.resolvingSymlinksInPath().path])
    #expect(current.contains(".package(path: \"../swift-log\")"))
    #expect(legacy.contains(".package(path: \"../swift-log\")"))
    #expect(!current.contains("github.com"))
    #expect(!legacy.contains("github.com"))
}

@Test func missingCheckoutWritesNothing() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.package(
        named: "App",
        source: """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(url: "https://github.com/example/Missing.git", from: "1.0.0"),
            ]
        )

        """
    )
    let manifest = app.appendingPathComponent("Package.swift")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let plan = try PackageRewriter.plan(packageDirectory: app, directoryPrefix: fixture.url.appendingPathComponent("deps"))
    #expect(plan.edits.isEmpty)
    #expect(plan.missing.isEmpty)
    #expect(plan.skippedURLs == ["https://github.com/example/Missing.git"])
    try PackageRewriter.apply(plan)
    #expect(try String(contentsOf: manifest, encoding: .utf8) == original)
    #expect(!FileManager.default.fileExists(atPath: manifest.path + ".back"))
}

@Test func missingURLStaysWhilePresentURLIsRewritten() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.package(
        named: "App",
        source: """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(url: "https://github.com/example/Missing.git", from: "1.0.0"),
                .package(url: "https://github.com/example/Example.git", from: "1.0.0"),
            ]
        )

        """
    )
    try fixture.package(named: "deps/Example", source: emptyPackage(name: "Example"))
    let plan = try PackageRewriter.plan(packageDirectory: app, directoryPrefix: fixture.url.appendingPathComponent("deps"))
    #expect(plan.skippedURLs == ["https://github.com/example/Missing.git"])
    let rewritten = try #require(plan.edits.first?.rewritten)
    #expect(rewritten.contains(".package(url: \"https://github.com/example/Missing.git\", from: \"1.0.0\")"))
    #expect(rewritten.contains(".package(path: \"../deps/Example\")"))
}

@Test func backupIsKeptWhenRewriteRunsAgain() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.package(
        named: "App",
        source: """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(url: "https://github.com/example/Example.git", from: "1.0.0"),
            ]
        )

        """
    )
    try fixture.package(named: "deps/Example", source: emptyPackage(name: "Example"))
    let manifest = app.appendingPathComponent("Package.swift")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let plan = try PackageRewriter.plan(packageDirectory: app, directoryPrefix: fixture.url.appendingPathComponent("deps"))
    try PackageRewriter.apply(plan)
    let backup = manifest.path + ".back"
    #expect(try String(contentsOfFile: backup, encoding: .utf8) == original)
    try "sentinel".write(toFile: backup, atomically: true, encoding: .utf8)
    try PackageRewriter.apply(plan)
    #expect(try String(contentsOfFile: backup, encoding: .utf8) == "sentinel")
    let again = try PackageRewriter.plan(packageDirectory: app, directoryPrefix: fixture.url.appendingPathComponent("deps"))
    #expect(again.edits.isEmpty)
}

private func manifestPath(_ directory: URL) -> String {
    directory.appendingPathComponent("Package.swift").standardizedFileURL.resolvingSymlinksInPath().path
}

private func emptyPackage(name: String) -> String {
    """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "\(name)")

    """
}

private struct Fixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("spm-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func package(named name: String, source: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try source.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return directory
    }
}
