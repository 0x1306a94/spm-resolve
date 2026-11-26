import Foundation

import ArgumentParser
import Basics
import DepctlDEPS
import PackageGraph
import PackageModel
import PackageRewrite
import Workspace

@main
struct SPMResolve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spm-resolve",
        abstract: "Resolve a package and print its dependency closure.",
        version: ToolVersion.current,
        subcommands: [Resolve.self, Rewrite.self],
        defaultSubcommand: Resolve.self
    )
}

struct Resolve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve",
        abstract: "Resolve a package and print its dependency closure."
    )

    @Argument(help: "Package directory, Package.swift, or a remote git URL.")
    var package: String

    @Flag(help: "Print depctl repository entries.")
    var depctl = false

    @Option(name: .customLong("dir-prefix"), help: ArgumentHelp("Directory prefix for depctl entries.", valueName: "path"))
    var directoryPrefix = "third_party/Packages"

    @Option(name: .customLong("version"), help: "Exact version of a remote package.")
    var version: String?

    @Option(name: .customLong("revision"), help: "Revision of a remote package.")
    var revision: String?

    func run() async throws {
        let resolved = try preparePackage(package, version: version, revision: revision)
        let observability = ObservabilitySystem { _, diagnostic in
            fputs("\(diagnostic)\n", stderr)
        }

        let workspace = try Workspace(
            fileSystem: localFileSystem,
            location: try workspaceLocation(scratchPath: resolved.scratchPath),
            initializationWarningHandler: { warning in
                fputs("warning: \(warning)\n", stderr)
            }
        )

        try await workspace.resolve(
            root: PackageGraphRootInput(packages: [resolved.packagePath]),
            forceResolution: true,
            observabilityScope: observability.topScope
        )

        if observability.topScope.errorsReported {
            Foundation.exit(1)
        }

        let store = try workspace.pinsStore.load()
        let pins = store.resolvedPackages.values.filter { pin in
            guard resolved.hideRoot else { return true }
            return (try? AbsolutePath(validating: pin.packageRef.locationString)) != resolved.packagePath
        }.sorted {
            $0.packageRef.locationString < $1.packageRef.locationString
        }
        if depctl {
            let repositories = try gitRepositories(pins)
            let text = try DepctlDEPSText.render(
                repositories: repositories,
                directoryPrefix: directoryPrefix
            )
            printResultMarker()
            print(text, terminator: "")
            return
        }

        printResultMarker()
        for pin in pins {
            let described = describe(pin.state)
            print("\(kindName(pin.packageRef.kind))\t\(pin.packageRef.locationString)\t\(described.revision)\t\(described.label)")
        }
    }
}

struct Rewrite: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rewrite",
        abstract: "Rewrite remote package dependencies to local paths."
    )

    @Argument(help: "Package directory or Package.swift.")
    var package: String

    @Option(name: .customLong("dir-prefix"), help: ArgumentHelp("Directory prefix for checked out dependencies, relative to the package.", valueName: "path"))
    var directoryPrefix = "third_party/Packages"

    func run() throws {
        let packagePath = try packageDirectory(package)
        let prefix = try absolutePath(directoryPrefix, relativeTo: packagePath)
        let plan = try PackageRewriter.plan(
            packageDirectory: URL(fileURLWithPath: packagePath.pathString, isDirectory: true),
            directoryPrefix: URL(fileURLWithPath: prefix.pathString, isDirectory: true)
        )
        for identifier in plan.skippedRegistries {
            fputs("skip registry \(identifier)\n", stderr)
        }
        for url in plan.skippedURLs {
            fputs("skip \(url)\n", stderr)
        }
        if !plan.missing.isEmpty {
            let lines = plan.missing.map { "missing \($0.reference) at \($0.expectedManifest)" }
            throw CommandError(lines.joined(separator: "\n"))
        }
        try PackageRewriter.apply(plan)
        for edit in plan.edits {
            print(edit.manifestPath)
        }
    }
}

private func printResultMarker() {
    fflush(stderr)
    print("--- spm-resolve ---")
}

private func gitRepositories(_ pins: [ResolvedPackagesStore.ResolvedPackage]) throws -> [DepctlRepository] {
    var repositories: [DepctlRepository] = []
    for pin in pins {
        let location = pin.packageRef.locationString
        guard case .remoteSourceControl = pin.packageRef.kind else {
            fputs("skip \(kindName(pin.packageRef.kind)) \(location)\n", stderr)
            continue
        }
        guard let text = resolvedText(pin.state) else {
            throw CommandError("no revision for \(location)")
        }
        repositories.append(DepctlRepository(url: location, commit: text.commit, comment: text.comment))
    }
    return repositories
}

private struct PreparedPackage {
    var packagePath: AbsolutePath
    var scratchPath: AbsolutePath
    var hideRoot: Bool
}

private func preparePackage(_ argument: String, version: String?, revision: String?) throws -> PreparedPackage {
    if isRemotePackageURL(argument) {
        let name = repositoryName(from: argument)
        if name.isEmpty {
            throw CommandError("cannot derive a directory name from \(argument)")
        }
        let manifest = try remoteRootManifest(url: argument, exactVersion: version, revision: revision)
        let selector = try cacheSelector(version: version, revision: revision)
        let directory = try resolveCacheRoot().appending(components: name, selector)
        try localFileSystem.createDirectory(directory, recursive: true)
        try manifest.write(
            to: URL(fileURLWithPath: directory.appending("Package.swift").pathString),
            atomically: true,
            encoding: .utf8
        )
        return PreparedPackage(packagePath: directory, scratchPath: directory, hideRoot: true)
    }
    if version != nil || revision != nil {
        throw CommandError("--version and --revision apply to a remote package URL")
    }
    let packagePath = try packageDirectory(argument)
    let scratchPath = try resolveCacheRoot().appending(packagePath.basename)
    return PreparedPackage(packagePath: packagePath, scratchPath: scratchPath, hideRoot: false)
}

private func cacheSelector(version: String?, revision: String?) throws -> String {
    let selector = version ?? revision ?? ""
    if selector.isEmpty || selector == "." || selector == ".." || selector.contains("/") || selector.contains("\\") {
        throw CommandError("version or revision cannot be used as a cache directory name")
    }
    return selector
}

private func packageDirectory(_ argument: String) throws -> AbsolutePath {
    let path = try absolutePath(argument)
    if path.basename == "Package.swift" {
        return path.parentDirectory
    }
    return path
}

private func absolutePath(_ argument: String) throws -> AbsolutePath {
    guard let workingDirectory = localFileSystem.currentWorkingDirectory else {
        throw CommandError("could not determine the working directory")
    }
    return try absolutePath(argument, relativeTo: workingDirectory)
}

private func absolutePath(_ argument: String, relativeTo base: AbsolutePath) throws -> AbsolutePath {
    let expanded = NSString(string: argument).expandingTildeInPath
    if let path = try? AbsolutePath(validating: expanded) {
        return path
    }
    return try AbsolutePath(validating: expanded, relativeTo: base)
}

private func resolveCacheRoot() throws -> AbsolutePath {
    try AbsolutePath(validating: NSString(string: "~/Library/Caches/org.spm.resolve").expandingTildeInPath)
}

private func workspaceLocation(scratchPath: AbsolutePath) throws -> Workspace.Location {
    let scratch = scratchPath
    try localFileSystem.createDirectory(scratch, recursive: true)
    return Workspace.Location(
        scratchDirectory: scratch.appending("build"),
        editsDirectory: scratch.appending("edits"),
        resolvedVersionsFile: scratch.appending("Package.resolved"),
        localConfigurationDirectory: scratch.appending("configuration"),
        sharedConfigurationDirectory: try localFileSystem.swiftPMConfigurationDirectory,
        sharedSecurityDirectory: try localFileSystem.swiftPMSecurityDirectory,
        sharedCacheDirectory: try localFileSystem.swiftPMCacheDirectory
    )
}

private func kindName(_ kind: PackageReference.Kind) -> String {
    switch kind {
    case .remoteSourceControl:
        return "git"
    case .localSourceControl:
        return "local-git"
    case .fileSystem:
        return "path"
    case .registry:
        return "registry"
    case .root:
        return "root"
    }
}

private func describe(_ state: ResolvedPackagesStore.ResolutionState) -> (revision: String, label: String) {
    switch state {
    case .version(let version, let revision):
        return (revision ?? "", version.description)
    case .branch(let name, let revision):
        return (revision, name)
    case .revision(let revision):
        return (revision, revision)
    }
}

private func resolvedText(_ state: ResolvedPackagesStore.ResolutionState) -> (commit: String, comment: String)? {
    switch state {
    case .version(let version, let revision):
        guard let revision, !revision.isEmpty else { return nil }
        return (revision, "\(version.description) version")
    case .branch(let name, let revision):
        guard !revision.isEmpty else { return nil }
        return (revision, "\(name) branch")
    case .revision(let revision):
        guard !revision.isEmpty else { return nil }
        return (revision, "revision")
    }
}

struct CommandError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
