import SwiftUI
import AppKit
import MoonlightCore

enum Theme {
    static let navy = Color(red: 0.10, green: 0.14, blue: 0.22)
    static let ink = Color(red: 0.14, green: 0.19, blue: 0.27)
    static let muted = Color(red: 0.46, green: 0.51, blue: 0.59)
    static let green = Color(red: 0.14, green: 0.54, blue: 0.43)
    static let background = Color(red: 0.95, green: 0.96, blue: 0.97)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var downloadSection = DownloadSection.vanilla
    @State private var loaderGame = "1.20.1"
    @Namespace private var sidebarSelection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                ZStack(alignment: .topLeading) {
                    ScrollView {
                        Group {
                            switch model.page {
                            case "下载": DownloadView(category: $downloadSection, loaderGame: $loaderGame)
                            case "版本": VersionsView()
                            case "模组": ModsView(openDownloads: openDownloads)
                            case "设置": SettingsView()
                            case "日志": LogsView()
                            default: HomeView { openDownloads($0) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(30)
                    }
                    .id(model.page)
                    .transition(reduceMotion ? .identity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity
                    ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.page)
                footer
            }.background(Theme.background)
        }
        .font(.system(size: 13)).foregroundStyle(Theme.ink)
        .sheet(isPresented: $model.loginSheet, onDismiss: { model.cancelLogin() }) { MicrosoftLoginSheet().environmentObject(model).interactiveDismissDisabled(model.authenticating) }
        .sheet(isPresented: $model.configurationSheet) { MicrosoftConfigurationSheet().environmentObject(model) }
        .alert("需要处理一下", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("查看日志") { model.page = "日志"; model.errorMessage = nil }
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func openDownloads(_ section: DownloadSection, for game: String? = nil) {
        if let game, section == .forge || section == .fabric { loaderGame = game }
        downloadSection = section
        model.page = "下载"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "moon.stars.fill").font(.system(size: 24)).foregroundStyle(Color(red: 0.69, green: 0.91, blue: 0.84))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Moonlight").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("月光启动器").font(.system(size: 10)).tracking(3).foregroundStyle(.white.opacity(0.45))
                }
            }.padding(.top, 55).padding(.bottom, 38).padding(.horizontal, 24)
            navigationGroup("游戏", items: [("启动", "play.circle"), ("下载", "arrow.down.to.line"), ("版本", "square.stack.3d.up"), ("模组", "puzzlepiece.extension")])
            navigationGroup("工具", items: [("设置", "slider.horizontal.3"), ("日志", "terminal")])
                .padding(.top, 18)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack { Circle().fill(Color(red: 0.53, green: 0.85, blue: 0.68)).frame(width: 6, height: 6); Text("为 Mac 而生").font(.system(size: 11)); Spacer(); Image(systemName: "apple.logo") }
                Text("\(Platform.label)  ·  v0.5.0").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }.foregroundStyle(.white.opacity(0.65)).padding(22).background(.white.opacity(0.035))
        }.frame(width: 212).background(Theme.navy).foregroundStyle(.white)
    }

    private func navigationGroup(_ title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 24)
                .padding(.bottom, 6)
            ForEach(items, id: \.0) { title, icon in
                SidebarNavigationItem(title: title, icon: icon, selected: model.page == title, selection: sidebarSelection) {
                    model.page = title
                }
                .padding(.horizontal, 12)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.page)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Minecraft Java 版", systemImage: "cube").fontWeight(.medium)
            Spacer()
            if model.running {
                Label("游戏运行中", systemImage: "gamecontroller.fill").foregroundStyle(Theme.green)
            }
            Button { model.page = "设置" } label: {
                Label(model.playerName, systemImage: "person.crop.circle")
                    .padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开账号与启动设置")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 30).frame(height: 52).background(.white)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if model.busy { ProgressView(value: model.progress).tint(Theme.green).progressViewStyle(.linear) }
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                else { Image(systemName: model.running ? "gamecontroller.fill" : "checkmark.circle").foregroundStyle(Theme.green) }
                Text(model.status).font(.system(size: 11)).lineLimit(1)
                Spacer()
                if model.busy { Text("\(Int(model.progress * 100))%").monospacedDigit(); Button("取消") { model.cancel() }.buttonStyle(.plain).foregroundStyle(Theme.green) }
                else if model.page != "日志" { Button("查看日志") { model.page = "日志" }.buttonStyle(.plain).foregroundStyle(Theme.green) }
            }.padding(.horizontal, 30).frame(height: 39).background(.white.opacity(0.8))
        }
    }
}

private struct SidebarNavigationItem: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    let title: String
    let icon: String
    let selected: Bool
    let selection: Namespace.ID
    let action: () -> Void

    private var label: String {
        switch title {
        case "版本": return "版本管理"
        case "下载": return "下载游戏"
        case "模组": return "模组管理"
        case "日志": return "启动日志"
        default: return title
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 22)
                Text(label).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.60, green: 0.88, blue: 0.76))
                    .frame(width: 3, height: 16).opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? .white : .white.opacity(hovered ? 0.85 : 0.52))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.09))
                        .matchedGeometryEffect(id: "sidebar-selection", in: selection)
                }
            }
            .background(.white.opacity(hovered && !selected ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    let openDownloads: (DownloadSection) -> Void

    private var locked: Bool { model.busy || model.authenticating || model.running }
    private var needsAccount: Bool { model.preferences.authenticationMode == "online" && model.activeAccount == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .leading) {
                    LandscapeView().accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 9) {
                        Label(model.running ? "游戏运行中" : "Minecraft Java 版", systemImage: "gamecontroller.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green)
                        Text(model.selected?.title ?? "安装第一个游戏版本")
                            .font(.system(size: 28, weight: .bold)).lineLimit(2)
                        Text(model.selected.map { "Minecraft \($0.gameID) · \($0.loaderLabel) · Java \($0.javaMajor)" } ?? "先选择原版或整合包。月光会一起准备所需的 Java。")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 175).padding(24)
                }
                .frame(height: 176)
                launchControls.padding(20)
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if model.installed.isEmpty {
                Text("选择游玩方式").font(.system(size: 17, weight: .semibold))
                HStack(alignment: .top, spacing: 12) {
                    HomeAction(title: "原版生存与创造", detail: "选择游戏版本即可开始。", icon: "cube") { openDownloads(.vanilla) }
                    HomeAction(title: "游玩整合包", detail: "搜索整合包，或导入本地压缩包。", icon: "shippingbox") { openDownloads(.packs) }
                }
            } else {
                Text("管理游戏").font(.system(size: 17, weight: .semibold))
                HStack(alignment: .top, spacing: 12) {
                    HomeAction(title: "版本与存档", detail: "打开游戏目录、修复版本或找回备份。", icon: "square.stack.3d.up") { model.page = "版本" }
                    HomeAction(title: "安装整合包", detail: "搜索 Modrinth，或导入本地整合包。", icon: "shippingbox") { openDownloads(.packs) }
                    HomeAction(title: "模组管理", detail: "查看已装模组，或搜索缺少的模组。", icon: "puzzlepiece.extension") { model.page = "模组" }
                }
            }
        }
    }

    private var launchControls: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if model.installed.isEmpty {
                    Text("首次安装").fontWeight(.semibold)
                    Text("纯净游戏从原版开始，有整合包文件可直接导入。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                } else {
                    Picker("启动版本", selection: $model.preferences.selected) {
                        ForEach(model.installed) { Text($0.displayName ?? "Minecraft \($0.gameID) · \($0.loaderLabel)").tag($0.id) }
                    }
                    .frame(maxWidth: 350).disabled(locked)
                    Button { model.page = "设置" } label: {
                        Label(model.modeLabel, systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).font(.system(size: 12))
                    .help("切换账号或启动模式")
                }
            }
            Spacer(minLength: 2)
            if model.running {
                primaryAction("结束游戏", icon: "stop.fill") { model.stop() }
            } else if model.installed.isEmpty {
                primaryAction("选择游戏版本", icon: "arrow.down") { openDownloads(.vanilla) }
            } else if needsAccount {
                primaryAction("设置游戏账号", icon: "person.crop.circle") { model.page = "设置" }
            } else {
                primaryAction("启动游戏", icon: "play.fill") { model.launch() }
            }
        }
        .disabled(model.busy || model.authenticating)
    }

    private func primaryAction(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(label, systemImage: icon).frame(minWidth: 126, minHeight: 42) }
            .buttonStyle(PrimaryButton())
    }
}

private struct HomeAction: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).foregroundStyle(Theme.green)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                }
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).foregroundStyle(Theme.muted).font(.system(size: 12))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 114, alignment: .topLeading)
            .background(hovered ? Theme.green.opacity(0.06) : .white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.green.opacity(hovered ? 0.40 : 0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

struct VanillaDownloadView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "安装原版", subtitle: "选择 Minecraft 正式版。要加入服务器时，请选择和服务器相同的游戏版本。")
            HStack {
                Label("正式版", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.green).padding(.horizontal, 13).padding(.vertical, 8).background(Theme.green.opacity(0.08), in: Capsule())
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("搜索版本，如 1.21", text: $model.search).textFieldStyle(.plain).frame(width: 160)
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.refreshing).help("刷新官方目录")
            }
            HStack { Text(model.catalogStatus); Spacer(); if model.refreshing { ProgressView().controlSize(.small) } }.font(.system(size: 11)).foregroundStyle(Theme.muted)
            if model.filteredVersions.isEmpty {
                EmptyCard(icon: "network", title: model.search.isEmpty ? "等待版本目录" : "没有匹配的版本", detail: model.search.isEmpty ? "连接网络后点击刷新。已安装的游戏仍可在首页启动。" : "试试其他版本号。")
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(model.filteredVersions) { version in versionRow(version) }
                }.clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text("下载需要连接 Mojang 和 Adoptium 服务；Java 按电脑芯片架构自动选择。首次安装的时间取决于网络情况。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
    private func versionRow(_ version: GameVersion) -> some View {
        let installed = model.installed.contains { $0.id == version.id }
        return HStack(spacing: 15) {
            Image(systemName: "cube.fill").font(.system(size: 21)).foregroundStyle(Theme.green).frame(width: 40, height: 40).background(Theme.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) { Text(version.id).font(.system(size: 15, weight: .semibold)); if version.id == model.latest { Text("最新正式版").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.green).padding(.horizontal, 7).padding(.vertical, 3).background(Theme.green.opacity(0.09), in: Capsule()) } }
                Text("原版  ·  \(version.dateLabel)").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if installed { Label("已安装", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.system(size: 11)) }
            Button { model.install(version) } label: { Label(installed ? "修复" : "安装", systemImage: installed ? "wrench" : "arrow.down").frame(width: 65, height: 29) }.buttonStyle(SecondaryButton()).disabled(model.busy || model.running || model.authenticating)
        }.padding(16).background(.white)
    }
}

struct VersionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var deleting: InstalledVersion?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { PageHeading(title: "版本管理", subtitle: "选择一个版本回到启动页，或在「游戏文件」中查看它的存档。"); Spacer(); Button("存档备份") { model.openFolder("backups/saves") }; Button("安装新版本") { model.page = "下载" }.buttonStyle(SecondaryButton()) }
            if let result = model.lastVersionRemoval {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("已删除 \(result.version.title)").fontWeight(.semibold)
                        Text(result.savesBackup != nil ? "存档已单独备份，重新安装后可复制回来。" : result.keptSaves ? "此版本没有本地存档；游戏目录已移至废纸篓。" : "游戏目录（含本地存档）已移至废纸篓。")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if let backup = result.savesBackup { Button("查看保留的存档") { NSWorkspace.shared.open(backup) }.buttonStyle(SecondaryButton()) }
                }.padding(18).card()
            }
            if model.installed.isEmpty {
                EmptyCard(icon: "square.stack.3d.up", title: "还没有安装版本", detail: "前往「下载游戏」安装游戏，或导入整合包。")
            }
            ForEach(model.installed) { version in
                HStack(spacing: 17) {
                    Image(systemName: "shippingbox.fill").font(.system(size: 27)).foregroundStyle(Theme.green).frame(width: 62, height: 62).background(Theme.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(version.title).font(.system(size: 17, weight: .semibold))
                        Text("\(version.gameID) · \(version.loaderLabel) · Java \(version.javaMajor)").foregroundStyle(Theme.muted).font(.system(size: 11))
                        Text("安装于 \(version.installedAt.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        Button(model.preferences.selected == version.id ? "返回启动页" : "选用并前往启动") { model.preferences.selected = version.id; model.page = "启动" }.buttonStyle(SecondaryButton()).disabled(model.busy || model.running || model.authenticating)
                        HStack(spacing: 14) {
                            Button("游戏文件") { model.openFolder("instances/\(version.id)") }
                            Button("修复环境") { model.repair(version) }.disabled(model.busy || model.running || model.authenticating)
                            Button("删除") { deleting = version }.foregroundStyle(.red).disabled(model.busy || model.running || model.authenticating)
                        }.buttonStyle(.plain).foregroundStyle(Theme.muted).font(.system(size: 10))
                    }
                }.padding(22).card()
            }
        }
        .sheet(item: $deleting) { version in DeleteVersionSheet(version: version).environmentObject(model) }
    }
}

private struct DeleteVersionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keepSaves = true
    let version: InstalledVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "删除这个版本？", subtitle: "\(version.title) · \(version.gameID) / \(version.loaderLabel)")
            Toggle("保留单人存档（推荐）", isOn: $keepSaves).toggleStyle(.checkbox).fontWeight(.semibold)
            Text(keepSaves ? "存档（saves）会单独保存在「存档备份」中；模组、配置、截图、日志等其余游戏文件移至废纸篓。" : "该版本的整个游戏目录，包括单人存档、模组、配置、截图与日志，都会移至废纸篓。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text("该版本会从列表移除。游戏本体、加载器、Java 和公共资源留作缓存，其他版本可继续使用。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(keepSaves ? "保留存档并删除" : "连同存档移至废纸篓") {
                    model.deleteVersion(version, keepSaves: keepSaves); dismiss()
                }.buttonStyle(.borderedProminent).tint(.red).disabled(model.busy || model.running || model.authenticating)
            }
        }.padding(28).frame(width: 540).background(Theme.background)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "启动设置", subtitle: "设置自动保存，下次启动游戏时生效。")
            AccountSettingsView()
            VStack(alignment: .leading, spacing: 20) {
                Label("性能与运行环境", systemImage: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
                HStack { Text("最大游戏内存"); Spacer(); Text("\(model.preferences.memory) MB").monospacedDigit().foregroundStyle(Theme.green).fontWeight(.semibold) }
                Slider(value: Binding(get: { Double(model.preferences.memory) }, set: { model.preferences.memory = Int($0) }), in: 1024...Double(model.memoryLimit), step: 512).tint(Theme.green)
                HStack { Text("1 GB"); Spacer(); Text("\(model.memoryLimit / 1024) GB") }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                Divider()
                HStack { Text("Java 运行环境"); Spacer(); Text(model.preferences.customJava.isEmpty ? "自动安装与管理" : "自定义").foregroundStyle(Theme.green) }
                HStack {
                    TextField("自动选择对应版本 Java（推荐）", text: $model.preferences.customJava).textFieldStyle(.roundedBorder)
                    Button("选择…") { model.selectJava() }
                    if !model.preferences.customJava.isEmpty { Button("恢复自动") { model.preferences.customJava = "" } }
                }
                Text("自动模式使用 Eclipse Temurin，支持 \(Platform.label)。自定义路径应指向 bin/java。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }.padding(23).card().disabled(model.busy || model.running || model.authenticating)
            VStack(alignment: .leading, spacing: 14) {
                HStack { Label("游戏数据目录", systemImage: "folder").font(.system(size: 15, weight: .semibold)); Spacer(); Button("在 Finder 中打开") { model.openFolder() } }
                Text(model.root.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                Text("Moonlight 是独立的 Minecraft 启动器项目，界面参考 PCL 的使用习惯，与 PCL 或 Mojang 无隶属关系。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(23).card()
        }
    }
}

struct LogsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { PageHeading(title: "启动日志", subtitle: "显示最近的启动输出，完整游戏日志保存在数据目录中。 "); Spacer(); Button("导出日志") { model.exportLogs() }; Button("日志文件夹") { model.openFolder("logs") } }
            ScrollView([.horizontal, .vertical]) {
                Text(model.logs).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(red: 0.70, green: 0.83, blue: 0.79)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
            }.frame(height: 450).background(Theme.navy, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct LandscapeView: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [Color(red: 0.88, green: 0.95, blue: 0.92), Color(red: 0.70, green: 0.86, blue: 0.86)]), startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
            let sun = CGRect(x: w * 0.79, y: 32, width: 65, height: 65)
            context.fill(Path(ellipseIn: sun.insetBy(dx: -12, dy: -12)), with: .color(.white.opacity(0.15)))
            context.fill(Path(ellipseIn: sun), with: .color(Color(red: 1, green: 0.98, blue: 0.85)))
            for layer in 0..<3 {
                var path = Path(); let base = h * (0.54 + Double(layer) * 0.16)
                path.move(to: CGPoint(x: w * 0.37, y: h))
                let points: [(Double, Double)] = [(0.37,0.22),(0.46,0.02),(0.52,0.11),(0.61,-0.10),(0.69,0.08),(0.76,-0.19),(0.86,0.04),(0.94,-0.08),(1.05,0.08)]
                for (x, y) in points { path.addLine(to: CGPoint(x: w * x + Double(layer) * 18, y: base + h * y)) }
                path.addLine(to: CGPoint(x: w + 100, y: h)); path.closeSubpath()
                let colors = [Color(red: 0.56, green: 0.74, blue: 0.74), Color(red: 0.35, green: 0.62, blue: 0.61), Color(red: 0.20, green: 0.44, blue: 0.44)]
                context.fill(path, with: .color(colors[layer].opacity(0.65)))
            }
            // A small isometric grass island, drawn locally without image dependencies.
            let x = w * 0.78, y = h * 0.60, unit = min(24.0, h * 0.105)
            func polygon(_ points: [(Double, Double)], _ color: Color) {
                var p = Path(); p.move(to: CGPoint(x: x + points[0].0 * unit, y: y + points[0].1 * unit))
                for point in points.dropFirst() { p.addLine(to: CGPoint(x: x + point.0 * unit, y: y + point.1 * unit)) }; p.closeSubpath()
                context.fill(p, with: .color(color))
            }
            polygon([(-3,0),(0,-1.5),(3,0),(0,1.5)], Color(red: 0.52, green: 0.72, blue: 0.41))
            polygon([(-3,0),(0,1.5),(0,3),(-3,1.5)], Color(red: 0.39, green: 0.38, blue: 0.29))
            polygon([(0,1.5),(3,0),(3,1.5),(0,3)], Color(red: 0.28, green: 0.32, blue: 0.26))
            polygon([(-3,0),(0,1.5),(0,1.85),(-3,0.35)], Color(red: 0.31, green: 0.52, blue: 0.32))
            polygon([(0,1.5),(3,0),(3,0.35),(0,1.85)], Color(red: 0.25, green: 0.43, blue: 0.28))
            context.fill(Path(CGRect(x: x - 5, y: y - 54, width: 10, height: 47)), with: .color(Color(red: 0.38, green: 0.34, blue: 0.24)))
            polygon([(-1.2,-2.5),(0,-3.1),(1.2,-2.5),(0,-1.9)], Color(red: 0.39, green: 0.61, blue: 0.36))
            polygon([(-1.2,-2.5),(0,-1.9),(0,-0.8),(-1.2,-1.4)], Color(red: 0.25, green: 0.47, blue: 0.30))
            polygon([(0,-1.9),(1.2,-2.5),(1.2,-1.4),(0,-0.8)], Color(red: 0.18, green: 0.39, blue: 0.27))
        }
    }
}

struct PageHeading: View {
    let title: String; let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 25, weight: .bold)); Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted) } }
}
struct EmptyCard: View {
    let icon: String; let title: String; let detail: String
    var body: some View { VStack(spacing: 15) { Image(systemName: icon).font(.system(size: 38)).foregroundStyle(Theme.green.opacity(0.5)); Text(title).font(.system(size: 18, weight: .semibold)); Text(detail).foregroundStyle(Theme.muted).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 75).card() }
}
struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).background(Theme.green.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4), in: RoundedRectangle(cornerRadius: 10)).contentShape(RoundedRectangle(cornerRadius: 10)) }
}
struct SecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View { configuration.label.padding(.horizontal, 12).padding(.vertical, 7).foregroundStyle(Theme.green.opacity(enabled ? 1 : 0.4)).background(Theme.green.opacity(configuration.isPressed ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 7)) }
}
extension View {
    func card() -> some View { background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.ink.opacity(0.035), lineWidth: 1)).shadow(color: Theme.ink.opacity(0.025), radius: 10, y: 3) }
}
