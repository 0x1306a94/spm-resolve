import Foundation

import DepctlDEPS
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

public struct PackageRewriteEdit: Equatable, Sendable {
    public var manifestPath: String
    public var rewritten: String

    public init(manifestPath: String, rewritten: String) {
        self.manifestPath = manifestPath
        self.rewritten = rewritten
    }
}

public struct MissingPackage: Equatable, Sendable {
    public var reference: String
    public var expectedManifest: String

    public init(reference: String, expectedManifest: String) {
        self.reference = reference
        self.expectedManifest = expectedManifest
    }
}

public struct PackageRewritePlan: Equatable, Sendable {
    public var edits: [PackageRewriteEdit]
    public var missing: [MissingPackage]
    public var skippedRegistries: [String]
    public var skippedURLs: [String]

    public init(
        edits: [PackageRewriteEdit],
        missing: [MissingPackage],
        skippedRegistries: [String],
        skippedURLs: [String]
    ) {
        self.edits = edits
        self.missing = missing
        self.skippedRegistries = skippedRegistries
        self.skippedURLs = skippedURLs
    }
}

public struct PackageRewriteError: Error, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public enum PackageRewriter {
    public static func plan(packageDirectory: URL, directoryPrefix: URL) throws -> PackageRewritePlan {
        let packageDirectory = canonical(packageDirectory)
        let directoryPrefix = canonical(directoryPrefix)
        guard !rootManifests(in: packageDirectory).isEmpty else {
            throw PackageRewriteError("package manifest not found at \(packageDirectory.appendingPathComponent("Package.swift").path)")
        }

        var visited: Set<String> = []
        var edits: [PackageRewriteEdit] = []
        var missing: [MissingPackage] = []
        var seenMissing: Set<String> = []
        var skippedRegistries: [String] = []
        var seenRegistries: Set<String> = []
        var skippedURLs: [String] = []
        var seenSkippedURLs: Set<String> = []

        func recordMissing(_ item: MissingPackage) {
            guard seenMissing.insert(item.expectedManifest).inserted else { return }
            missing.append(item)
        }

        func visit(directory: URL) throws {
            let directory = canonical(directory)
            guard visited.insert(directory.path).inserted else { return }
            let manifests = rootManifests(in: directory)
            guard !manifests.isEmpty else {
                throw PackageRewriteError("package manifest not found at \(directory.appendingPathComponent("Package.swift").path)")
            }
            let sources = try manifests.map { manifest in
                let source = try String(contentsOf: manifest, encoding: .utf8)
                return (manifest, source, try packageDependencies(in: source))
            }
            var relativePaths: [String: String] = [:]
            for (_, _, dependencies) in sources {
                for dependency in dependencies {
                    switch dependency {
                    case .url(let url):
                        let name = repositoryName(from: url)
                        if name.isEmpty {
                            throw PackageRewriteError("cannot derive a directory name from \(url)")
                        }
                        let destination = canonical(directoryPrefix.appendingPathComponent(name, isDirectory: true))
                        if rootManifests(in: destination).isEmpty {
                            if seenSkippedURLs.insert(url).inserted {
                                skippedURLs.append(url)
                            }
                            continue
                        }
                        if relativePaths[url] == nil {
                            relativePaths[url] = relativePath(from: directory, to: destination)
                            try visit(directory: destination)
                        }
                    case .path(let path):
                        let destination = canonical(resolve(path: path, relativeTo: directory))
                        if rootManifests(in: destination).isEmpty {
                            recordMissing(MissingPackage(
                                reference: path,
                                expectedManifest: destination.appendingPathComponent("Package.swift").path
                            ))
                            continue
                        }
                        try visit(directory: destination)
                    case .registry(let identifier):
                        if seenRegistries.insert(identifier).inserted {
                            skippedRegistries.append(identifier)
                        }
                    }
                }
            }
            guard !relativePaths.isEmpty else { return }
            for (manifest, source, _) in sources {
                let rewritten = try rewrite(source: source, relativePaths: relativePaths)
                guard rewritten != source else { continue }
                edits.append(PackageRewriteEdit(manifestPath: manifest.path, rewritten: rewritten))
            }
        }

        try visit(directory: packageDirectory)
        return PackageRewritePlan(
            edits: edits,
            missing: missing,
            skippedRegistries: skippedRegistries,
            skippedURLs: skippedURLs
        )
    }

    public static func apply(_ plan: PackageRewritePlan) throws {
        if !plan.missing.isEmpty {
            throw PackageRewriteError("refusing to rewrite while checkouts are missing")
        }
        let manager = FileManager.default
        for edit in plan.edits {
            let manifest = URL(fileURLWithPath: edit.manifestPath)
            let backup = URL(fileURLWithPath: edit.manifestPath + ".back")
            if !manager.fileExists(atPath: backup.path) {
                try manager.copyItem(at: manifest, to: backup)
            }
            try edit.rewritten.write(to: manifest, atomically: true, encoding: .utf8)
        }
    }
}

private enum PackageDependency {
    case url(String)
    case path(String)
    case registry(String)
}

private func packageDependencies(in source: String) throws -> [PackageDependency] {
    let scanner = DependencyScanner(viewMode: .sourceAccurate)
    scanner.walk(Parser.parse(source: source))
    if let failure = scanner.failure {
        throw failure
    }
    return scanner.dependencies
}

private func rewrite(source: String, relativePaths: [String: String]) throws -> String {
    let rewriter = URLDependencyRewriter(relativePaths: relativePaths)
    let rewritten = rewriter.rewrite(Parser.parse(source: source))
    if let failure = rewriter.failure {
        throw failure
    }
    return rewritten.description
}

private final class DependencyScanner: SyntaxVisitor {
    var dependencies: [PackageDependency] = []
    var failure: PackageRewriteError?

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard failure == nil else { return .skipChildren }
        do {
            if let dependency = try classify(node) {
                dependencies.append(dependency)
            }
        } catch let error as PackageRewriteError {
            failure = error
            return .skipChildren
        } catch {
            failure = PackageRewriteError(String(describing: error))
            return .skipChildren
        }
        return .visitChildren
    }
}

private final class URLDependencyRewriter: SyntaxRewriter {
    var relativePaths: [String: String]
    var failure: PackageRewriteError?

    init(relativePaths: [String: String]) {
        self.relativePaths = relativePaths
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        guard failure == nil else { return ExprSyntax(node) }
        do {
            guard case .url(let url) = try classify(node), let relative = relativePaths[url] else {
                return super.visit(node)
            }
            return pathCall(relative, original: node)
        } catch let error as PackageRewriteError {
            failure = error
            return ExprSyntax(node)
        } catch {
            failure = PackageRewriteError(String(describing: error))
            return ExprSyntax(node)
        }
    }
}

private func classify(_ call: FunctionCallExprSyntax) throws -> PackageDependency? {
    guard isPackageCall(call) else { return nil }
    if let expression = argument(labeled: "url", in: call) {
        guard let url = stringValue(expression) else {
            throw PackageRewriteError("package url is not a string literal")
        }
        return .url(url)
    }
    if let expression = argument(labeled: "path", in: call) {
        guard let path = stringValue(expression) else {
            throw PackageRewriteError("package path is not a string literal")
        }
        return .path(path)
    }
    if let expression = argument(labeled: "id", in: call) {
        guard let identifier = stringValue(expression) else {
            throw PackageRewriteError("package identifier is not a string literal")
        }
        return .registry(identifier)
    }
    return nil
}

private func isPackageCall(_ call: FunctionCallExprSyntax) -> Bool {
    if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
        return member.declName.baseName.text == "package"
    }
    if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
        return reference.baseName.text == "package"
    }
    return false
}

private func argument(labeled name: String, in call: FunctionCallExprSyntax) -> ExprSyntax? {
    call.arguments.first { $0.label?.text == name }?.expression
}

private func stringValue(_ expression: ExprSyntax) -> String? {
    expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
}

private func pathCall(_ relative: String, original: FunctionCallExprSyntax) -> ExprSyntax {
    var expression = ExprSyntax(stringLiteral: ".package(path: \(swiftLiteral(relative)))")
    expression.leadingTrivia = original.leadingTrivia
    expression.trailingTrivia = original.trailingTrivia
    return expression
}

private func swiftLiteral(_ value: String) -> String {
    var encoded = "\""
    for character in value {
        switch character {
        case "\\":
            encoded += "\\\\"
        case "\"":
            encoded += "\\\""
        case "\n":
            encoded += "\\n"
        case "\r":
            encoded += "\\r"
        default:
            encoded.append(character)
        }
    }
    encoded += "\""
    return encoded
}

private func rootManifests(in directory: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter(isRootManifest).sorted().map { directory.appendingPathComponent($0) }
}

private func isRootManifest(_ name: String) -> Bool {
    if name == "Package.swift" {
        return true
    }
    let prefix = "Package@swift-"
    let suffix = ".swift"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
    let version = name.dropFirst(prefix.count).dropLast(suffix.count)
    return !version.isEmpty && version.allSatisfy { $0.isNumber || $0 == "." }
}

private func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}

private func resolve(path: String, relativeTo directory: URL) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    let expanded = NSString(string: path).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
    return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: directory)
}

private func relativePath(from directory: URL, to destination: URL) -> String {
    let fromParts = pathComponents(directory)
    let toParts = pathComponents(destination)
    var index = 0
    while index < fromParts.count && index < toParts.count && fromParts[index] == toParts[index] {
        index += 1
    }
    let parts = Array(repeating: "..", count: fromParts.count - index) + toParts[index...]
    if parts.isEmpty {
        return "."
    }
    return parts.joined(separator: "/")
}

private func pathComponents(_ url: URL) -> [String] {
    url.path.split(separator: "/").map(String.init)
}
