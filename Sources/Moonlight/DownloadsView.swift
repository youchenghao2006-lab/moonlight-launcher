import SwiftUI
import MoonlightCore

enum DownloadSection: String, CaseIterable {
    case vanilla = "原版"
    case forge = "Forge"
    case fabric = "Fabric"
    case packs = "整合包"
}

struct DownloadView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var category: DownloadSection
    @Binding var loaderGame: String
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("下载内容", selection: $category) {
                ForEach(DownloadSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ZStack(alignment: .topLeading) {
                Group {
                    switch category {
                    case .vanilla: VanillaDownloadView()
                    case .forge: LoaderDownloadView(loader: "forge", game: $loaderGame)
                    case .fabric: LoaderDownloadView(loader: "fabric", game: $loaderGame)
                    case .packs: ModpackDownloadView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(category)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity
                ))
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: category)
        }
    }
}

struct LoaderDownloadView: View {
    @EnvironmentObject var model: AppModel
    let loader: String
    @Binding var game: String
    @State private var builds: [LoaderBuild] = []
    @State private var loading = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "安装 \(loader.capitalized)", subtitle: "先选 Minecraft 版本，再安装模组加载器。Java 与游戏文件会自动准备。")
            HStack {
                Picker("游戏版本", selection: $game) {
                    if !model.versions.contains(where: { $0.id == game }) { Text(game).tag(game) }
                    ForEach(model.versions) { Text($0.id).tag($0.id) }
                }.frame(width: 260)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await load() } }.disabled(loading)
            }
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.muted)
            ForEach(builds) { build in
                HStack(spacing: 16) {
                    Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 24)).foregroundStyle(Theme.green)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(loader.capitalized) \(build.version)").font(.system(size: 16, weight: .semibold))
                        Text("Minecraft \(game)\(build.recommended ? " · 官方推荐" : "")").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    let exists = model.installed.contains { $0.gameID == game && $0.loader == loader && $0.loaderVersion == build.version && $0.displayName == nil }
                    Button(exists ? "已安装" : "安装") {
                        if let version = model.versions.first(where: { $0.id == game }) { model.installLoader(version, loader: loader, build: build.version) }
                    }.buttonStyle(SecondaryButton()).disabled(exists || model.busy || model.running || model.authenticating || model.versions.isEmpty)
                }.padding(20).card()
            }
            if !loading && builds.isEmpty { EmptyCard(icon: "puzzlepiece.extension", title: "没有可用的加载器版本", detail: "换一个 Minecraft 版本，或稍后刷新。") }
            Text(loader == "forge" ? "显示 Forge 官方推荐版和最新版；整合包导入会自动安装作者指定的 Forge 版本。" : "显示 Fabric 官方稳定版本；请确保添加的模组适用于所选游戏版本。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }.task(id: game + loader) { await load() }
    }
    @MainActor private func load() async {
        loading = true; message = "正在获取官方加载器目录…"; builds = []
        do {
            let result = try await model.installer.loaderBuilds(game: game, loader: loader)
            guard !Task.isCancelled else { return }
            builds = result; message = "来自 \(loader.capitalized) 官方 · \(result.count) 个可安装版本"
        } catch { if !Task.isCancelled { message = "获取失败：\(error.localizedDescription)" } }
        if !Task.isCancelled { loading = false }
    }
}

struct ModpackDownloadView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var game = ""
    @State private var loader = ""
    @State private var projects: [PackProject] = []
    @State private var loading = false
    @State private var message = ""
    @State private var project: PackProject?
    @State private var optionalFiles = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                PageHeading(title: "下载安装整合包", subtitle: "搜索名称后选择版本。手里已有文件时，点「导入本地整合包」。")
                Spacer()
                Button { model.choosePack(optionalFiles: optionalFiles) } label: { Label("导入本地整合包", systemImage: "shippingbox.and.arrow.backward") }.buttonStyle(SecondaryButton()).disabled(model.busy || model.running || model.authenticating)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("搜索整合包名称（支持英文名称）", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("搜索") { Task { await search() } }.buttonStyle(SecondaryButton()).disabled(loading)
            }
            HStack {
                TextField("游戏版本，如 1.20.1（可留空）", text: $game).textFieldStyle(.roundedBorder).frame(maxWidth: 270).onSubmit { Task { await search() } }
                Picker("加载器", selection: $loader) { Text("全部").tag(""); Text("Forge").tag("forge"); Text("Fabric").tag("fabric") }.frame(width: 175)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Toggle("包含作者标记的可选文件", isOn: $optionalFiles).font(.system(size: 11)).toggleStyle(.checkbox)
            Text("支持 Modrinth 格式的 .mrpack 和 ZIP；暂不支持 CurseForge 清单包、普通备份 ZIP 和 EXE 安装器。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.muted)
            LazyVStack(spacing: 12) {
                ForEach(projects) { item in
                    HStack(spacing: 16) {
                        Image(systemName: "shippingbox.fill").font(.system(size: 25)).foregroundStyle(Theme.green).frame(width: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.system(size: 16, weight: .semibold))
                            Text(item.description).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                            Text("\(item.downloads.formatted()) 次下载 · Modrinth").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("选择版本") { project = item }.buttonStyle(SecondaryButton()).disabled(model.busy || model.running || model.authenticating)
                    }.padding(20).card()
                }
            }
            if projects.isEmpty && !loading { EmptyCard(icon: "shippingbox", title: "没有找到整合包", detail: "试试英文名称，或使用右上角的本地导入。") }
        }.task { if projects.isEmpty { await search() } }
        .sheet(item: $project) { item in PackVersionsSheet(project: item, game: game.trimmingCharacters(in: .whitespaces), loader: loader, optionalFiles: optionalFiles).environmentObject(model) }
    }
    @MainActor private func search() async {
        guard !loading else { return }
        loading = true; message = "正在搜索 Modrinth…"
        defer { loading = false }
        do {
            projects = try await PackCatalog.search(query, game: game.trimmingCharacters(in: .whitespaces), loader: loader)
            message = "Modrinth · 显示 \(projects.count) 个结果 · Forge / Fabric 可直接安装"
        } catch { message = "搜索失败：\(error.localizedDescription)" }
    }
}

struct PackVersionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let project: PackProject
    let game: String
    let loader: String
    let optionalFiles: Bool
    @State private var releases: [PackRelease] = []
    @State private var message = "正在获取版本…"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { PageHeading(title: project.title, subtitle: "选择整合包版本，自动安装其游戏与加载器。"); Spacer(); Button("关闭") { dismiss() } }
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.muted)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(releases) { release in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(release.name).fontWeight(.semibold)
                                Text("Minecraft \(release.game_versions.joined(separator: ", ")) · \(release.loaders.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button(release.supported ? "安装" : "暂不支持") { model.installPack(release, optionalFiles: optionalFiles); dismiss() }.buttonStyle(SecondaryButton()).disabled(!release.supported || model.busy || model.running || model.authenticating)
                        }.padding(15).card()
                    }
                }
            }
        }.padding(26).frame(width: 680, height: 520).background(Theme.background)
        .task {
            do {
                let all = try await PackCatalog.releases(project.id)
                releases = all.filter { (game.isEmpty || $0.game_versions.contains(game)) && (loader.isEmpty || $0.loaders.contains(loader)) }
                message = releases.isEmpty ? "没有符合筛选条件的版本。" : "共 \(releases.count) 个版本 · 当前支持 Minecraft 1.19+、Forge、Fabric"
            } catch { message = "读取失败：\(error.localizedDescription)" }
        }
    }
}
