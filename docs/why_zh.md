# 为什么做 spm-resolve

[English](why.md)

Swift 包的依赖闭包是解析出来的，不是手写就能列全的。根清单上往往只有一两个 URL，每个依赖自己的 `Package.swift` 里还有下一层。集成时要先拿到每个仓库的 URL 和 commit，交给 [depctl](https://github.com/0x1306a94/depctl) 拉到 `third_party/Packages/<仓库名>`，再让 SwiftPM 直接使用这些本地目录。

`spm-resolve` 做两件事。解析用 SwiftPM 的 `Workspace.resolve` 得到 pin，`--depctl` 打出可粘贴进 DEPS 的条目。改写把闭包里每份清单的远程依赖改成相对 `.package(path:)`。拉取由 depctl 完成。

## mirrors.json 不适用

SwiftPM 的 `mirrors.json` 是一张替换表。解析依赖时，`DependencyMirrors.effective(for:)` 用清单里的地址做键，整段字符串完全相等才替换。不是按仓库名匹配，也不是模糊匹配。

`https://github.com/example/Example.git` 和 `https://github.com/example/Example` 是两条配置。依赖清单里这两种写法都会出现，只写一条时另一条仍走原来的地址。`https` 和 `git@` 同样要分开写。

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

mirror 指向本地目录时也不支持相对路径。`DependencyMirrors` 只有在路径能按绝对路径解析时才把它当成本地目录，相对路径不会按清单所在位置换算。换一台机器或换一个检出目录，绝对路径就要改。

mirror 只替换地址，不改变依赖种类。清单里仍是 `.package(url:)` 时，SwiftPM 把它当远程 Git 依赖。拉取缓存时走 `GitRepository.fetch`，实现是 `git clone --mirror`，并且故意不做浅克隆。把 mirror 指到 depctl 的浅克隆目录，SwiftPM 仍会按远程仓库再克隆一份，用不上已经拉好的工作区。

只给根包配 mirror 也不够。依赖包自己的 `Package.swift` 里还有 URL，加载那份清单时会继续查表。闭包里每一个地址、每一种写法都要有记录。

## 改成 path 之后

`.package(path:)` 没有 URL scheme，相对路径按这份清单所在目录解析，源码直接用这个目录，不会 `git clone --mirror`。depctl 拉下来的目录因此可以直接被引用。代价是闭包里每一份清单都要改，不能只改根包。`from`、`branch`、`revision` 这些版本要求也会去掉，版本由 depctl 检出的那次 commit 决定。

`spm-resolve rewrite` 从根清单顺着依赖声明往下走，只把 `--dir-prefix` 下已经存在的远程依赖改成相对 path，并同时改 `Package.swift` 和 `Package@swift-*.swift`。registry 依赖没有 Git 仓库，mirror 和 path 都替代不了，保持原样。
