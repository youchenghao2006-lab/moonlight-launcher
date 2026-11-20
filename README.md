# Moonlight 月光启动器

Moonlight 是一个用 SwiftUI 编写的 macOS Minecraft Java 版启动器。你可以用它安装原版、Forge 或 Fabric，为每个整合包保留独立的模组、设置和单人存档。

## 从源码运行

需要 macOS 13 或更高版本、Swift 5.9 或更高版本，以及 Python 3（打包图标时使用）。在终端运行 `xcode-select --install` 可以安装 Apple 命令行开发工具。下载并解压仓库源码，进入含有 `Package.swift` 的目录后执行：

```sh
zsh scripts/build-app.sh
open dist/Moonlight.app
```

也可以把生成的 `Moonlight.app` 拖入「应用程序」。同目录的 `Moonlight-macOS.zip` 可用于传输。脚本生成当前 Mac 架构的应用并进行本地签名。项目在 Apple Silicon 上验证过，Intel 架构可在对应机器上构建。

## 第一次启动游戏

1. 打开「下载游戏」，选择原版、Forge 或 Fabric，选定 Minecraft 版本后安装。首次安装会联网准备所需版本的 Java、游戏文件和依赖。
2. 如需游玩整合包，在「下载游戏 → 整合包」搜索 Modrinth，或使用「导入本地整合包」选择 Modrinth 格式的 `.mrpack` 或 ZIP。
3. 回到「启动」选中刚安装的版本，检查游戏身份后点击「启动游戏」。需要正版验证的服务器须使用持有 Java 版游戏资格的微软账号。公开源码需要配置获准的微软应用 Client ID，配置步骤见[微软登录说明](docs/Microsoft登录配置.html)。

## 管理游戏

| 想做什么 | 在哪里操作 |
| --- | --- |
| 安装服务器指定的模组 | 在「模组管理」选中同一实例，进入「搜索下载」，按模组名称查找并选定版本。确认必需依赖后安装。 |
| 调整整合包的模组 | 在「模组管理 → 已安装」中筛选、停用或启用。替换和移除的文件可以从实例备份找回。 |
| 修复 Java、加载器或启动依赖 | 在「版本管理」找到对应版本，点「修复环境」。 |
| 删除版本并留住单人世界 | 在「版本管理」点「删除」，保持「保留单人存档」勾选。以后可从「存档备份」打开备份，在重装后将所需世界复制到该实例的 `saves` 目录。 |
| 调整内存和 Java 路径 | 打开「设置」。留空 Java 路径时，由启动器为所选游戏自动准备对应版本。 |

目前支持 Minecraft 1.19 起的受支持正式版、Forge、Fabric 以及 Modrinth 格式整合包。模组搜索按游戏版本与加载器过滤。与服务器联机时还需选择服主要求的模组版本。快照、NeoForge、Quilt 和 CurseForge 清单包尚未支持。

## 开发和自检

用下面的命令运行本地核心检查。测试覆盖平台与架构筛选、安装和启动参数、模组依赖与替换、失败恢复、存档保留、模拟登录和令牌脱敏。测试使用临时目录和合成样本。

```sh
swift run MoonlightCoreTests
```

若要单独验证真实下载和游戏启动，可以使用隔离目录。下面的命令联网安装原版 1.21.1，启动游戏，检测到音频初始化后结束测试进程。游戏文件留在指定目录，供重复验证时复用。

```sh
swift run MoonlightCheck "$PWD/.smoke-data" 1.21.1 --launch
```

开发时可通过 `MOONLIGHT_DATA_DIR` 指定游戏数据目录。默认目录是 `~/Library/Application Support/Moonlight`。每个实例的世界位于 `instances/<实例 ID>/saves`。登录凭证存放在 macOS 钥匙串，游戏数据目录的环境变量不改变钥匙串服务。

| 目录 | 用途 |
| --- | --- |
| `Sources/Moonlight` | SwiftUI 页面、账号设置和启动器状态 |
| `Sources/MoonlightCore` | 下载安装、启动、模组、存档和账号协议 |
| `Sources/MoonlightCheck` | 联网安装和启动验证工具 |
| `Tests/MoonlightCoreTests` | 离线核心检查和测试素材 |
| `scripts` | macOS 应用打包与图标生成 |

## 许可证与第三方内容

Moonlight 的原创源码、文档和打包脚本以 [MIT 许可证](LICENSE) 分发。本仓库仅提供启动器源码和测试样本。Minecraft、游戏资源、Java 运行时、加载器、模组及整合包由启动器从相应来源下载，各自适用其作者的条款。Moonlight 是独立项目，与 Mojang、Microsoft 和 PCL 无隶属关系。
