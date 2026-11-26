# Why spm-resolve

[中文](why_zh.md)

A Swift package's dependency closure comes from resolution. It cannot be listed by hand from the root manifest alone. The root often declares only one or two URLs, and each dependency's own `Package.swift` declares the next layer. Vendoring them means collecting every repository URL and commit, letting [depctl](https://github.com/0x1306a94/depctl) fetch them into `third_party/Packages/<repository-name>`, then making SwiftPM use those local directories.

`spm-resolve` does two of those steps. Resolution uses SwiftPM's `Workspace.resolve` to obtain pins, and `--depctl` prints entries that can be pasted into a DEPS file. Rewrite turns remote dependencies in every manifest in the closure into relative `.package(path:)` declarations. depctl does the fetch.

## Why mirrors.json does not fit

SwiftPM's `mirrors.json` is a replacement table. During resolution, `DependencyMirrors.effective(for:)` looks up the address written in the manifest. The whole string must match. It does not match on repository name, and it is not a fuzzy match.

`https://github.com/example/Example.git` and `https://github.com/example/Example` are two entries. Both spellings appear in package manifests. If only one is configured, the other still uses its original address. `https` and `git@` must be entered separately as well.

```json
{
  "version": 1,
  "object": [
    {
      "original": "https://github.com/example/Example.git",
      "mirror": "/absolute/path/to/Example"
    },
    {
      "original": "https://github.com/example/Example",
      "mirror": "/absolute/path/to/Example"
    }
  ]
}
```

A mirror that points at a local directory does not accept a relative path. `DependencyMirrors` treats the value as a local directory only when it parses as an absolute path. A relative path is not resolved against the manifest. Moving the checkout to another machine or another directory means rewriting those absolute paths.

A mirror replaces the address and does not change the kind of dependency. While the manifest still says `.package(url:)`, SwiftPM treats it as a remote Git dependency. The cache fetch goes through `GitRepository.fetch`, which runs `git clone --mirror` and intentionally does not make a shallow clone. Pointing the mirror at a shallow depctl checkout still makes SwiftPM clone the remote repository again. The checkout depctl already made is not used as the source.

Mirroring only the root package is not enough either. A dependency's own `Package.swift` still contains URLs, and loading that manifest looks them up in the table. Every address in the closure, in every spelling, needs its own entry.

## After switching to path

`.package(path:)` has no URL scheme. A relative path is resolved against the directory that contains that manifest, and the sources are read from that directory. There is no `git clone --mirror`. A directory fetched by depctl can be referenced directly. The cost is that every manifest in the closure must be rewritten, not only the root. `from`, `branch`, and `revision` requirements are dropped. The version is the commit depctl checked out.

`spm-resolve rewrite` walks dependency declarations from the root manifest. It rewrites a remote dependency to a relative path only when that package exists under `--dir-prefix`, and it rewrites both `Package.swift` and `Package@swift-*.swift`. A registry dependency has no Git repository. Neither a mirror nor a path can replace it, so it is left as it is.
