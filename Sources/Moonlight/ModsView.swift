import SwiftUI
import MoonlightCore

struct ModsView: View {
    let openDownloads: (DownloadSection, String?) -> Void
    @EnvironmentObject var model: AppModel
    @State private var tab = "已安装"
    @State private var query = ""
    @State private var localQuery = ""
    @State private var mods: [LocalMod] = []
    @State private var projects: [PackProject] = []
    @State private var loading = false
    @State private var searching = false
    @State private var message = "输入名称搜索，支持英文名或项目关键词。"
    @State private var localMessage = ""
    @State private var project: PackProject?
    @State private var removing: LocalMod?
    private var locked: Bool { model.busy || model.running || model.authenticating }
    private var target: InstalledVersion? { model.selected }
    private var filtered: [LocalMod] {
        mods.filter { localQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(localQuery) || $0.filename.localizedCaseInsensitiveContains(localQuery) || $0.modIDs.contains(where: { $0.localizedCaseInsensitiveContains(localQuery) }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "模组管理", subtitle: "先选要修改的游戏版本。在「搜索下载」输入模组名，可按服务器要求选择旧版。")
            HStack {
                Picker("游戏实例", selection: $model.preferences.selected) {
                    if model.installed.isEmpty { Text("请先安装游戏").tag("") }
                    ForEach(model.installed) { Text("\($0.title) · \($0.loaderLabel)").tag($0.id) }
                }.frame(maxWidth: 450).disabled(locked || loading)
                Spacer()
                if let target { Text("\(target.gameID) · \(target.loaderLabel)").foregroundStyle(Theme.green).font(.system(size: 12, weight: .medium)) }
            }
            if model.running { Label("请先退出游戏，再安装或调整模组。", systemImage: "gamecontroller").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            if let target {
                if !["forge", "fabric"].contains(target.loader ?? "") {
                    EmptyCard(icon: "puzzlepiece.extension", title: "此版本使用原版 Minecraft", detail: "先安装模组要求的加载器，再在上方选择对应的游戏版本。")
                    HStack {
                        Button("下载 Forge") { openDownloads(.forge, target.gameID) }
                        Button("下载 Fabric") { openDownloads(.fabric, target.gameID) }
                    }.buttonStyle(SecondaryButton())
                } else {
                    Picker("模组内容", selection: $tab) { Text(loading ? "正在读取模组…" : "已安装（\(mods.count)）").tag("已安装"); Text("搜索下载").tag("搜索下载") }.pickerStyle(.segmented)
                    if tab == "已安装" { installedList(target) } else { searchList(target) }
                }
            } else {
                EmptyCard(icon: "shippingbox", title: "先安装支持模组的游戏版本", detail: "可以使用 Forge、Fabric 或带有加载器的整合包。")
                HStack {
                    Button("下载 Forge") { openDownloads(.forge, nil) }
                    Button("下载 Fabric") { openDownloads(.fabric, nil) }
                    Button("选择整合包") { openDownloads(.packs, nil) }
                }.buttonStyle(SecondaryButton())
            }
        }
        .task(id: "\(target?.id ?? ""):\(model.modRevision)") { await loadInstalled() }
        .onChange(of: model.preferences.selected) { _ in projects = []; message = "已切换游戏实例，请重新搜索。" }
        .sheet(item: $project) { item in
            if let target { ModVersionsSheet(project: item, target: target).environmentObject(model) }
        }
        .alert("移除这个模组？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移至备份") { if let mod = removing, let target { model.changeMod(mod, target: target, remove: true) }; removing = nil }
            Button("取消", role: .cancel) { removing = nil }
        } message: { Text("\(removing?.title ?? "") 会从当前实例移至备份文件夹，可手动恢复。依赖它的模组可能需要一并调整。") }
    }

    private func installedList(_ target: InstalledVersion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("筛选名称、模组 ID 或文件名", text: $localQuery).textFieldStyle(.roundedBorder)
                if loading { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await loadInstalled() } }.disabled(loading || model.busy)
                Button("模组文件夹") { model.openFolder("instances/\(target.id)/mods") }
                Button("备份") { model.openFolder("backups/mods/\(target.id)") }
            }
            if !localMessage.isEmpty { Text(localMessage).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            if filtered.isEmpty && !loading { EmptyCard(icon: "puzzlepiece.extension", title: mods.isEmpty ? "还没有模组" : "没有匹配的模组", detail: mods.isEmpty ? "切换到「搜索下载」，为当前实例安装模组。" : "试试模组 ID 或文件名。") }
            LazyVStack(spacing: 10) {
                ForEach(filtered) { mod in
                    HStack(spacing: 14) {
                        Image(systemName: mod.enabled ? "puzzlepiece.extension.fill" : "pause.circle").font(.system(size: 22)).foregroundStyle(mod.enabled ? Theme.green : Theme.muted).frame(width: 32)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(mod.title).font(.system(size: 14, weight: .semibold)); Text(mod.enabled ? "已启用" : "已停用").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                            if !mod.version.isEmpty { Text(mod.version).font(.system(size: 11)).foregroundStyle(Theme.green) }
                            Text(mod.filename).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).help(mod.filename)
                        }
                        Spacer(minLength: 8)
                        Button(mod.enabled ? "停用" : "启用") { model.changeMod(mod, target: target) }.buttonStyle(SecondaryButton()).disabled(locked || loading)
                        Button("移除") { removing = mod }.buttonStyle(.plain).foregroundStyle(Theme.muted).disabled(locked || loading)
                    }.padding(16).card()
                }
            }
            Text("停用会保留模组文件；替换和移除的旧文件保存在实例备份中。整合包的模组相互依赖，调整后下次启动生效。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func searchList(_ target: InstalledVersion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("搜索模组，如 Moonlight Lib、MmmMmmMmmMmm", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await search(target) } }
                Button("搜索") { Task { await search(target) } }.buttonStyle(SecondaryButton()).disabled(searching)
                if searching { ProgressView().controlSize(.small) }
            }
            Text("自动筛选 Minecraft \(target.gameID) / \(target.loaderLabel)；可选择旧版本以匹配服务器。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.muted)
            LazyVStack(spacing: 12) {
                ForEach(projects) { item in
                    HStack(spacing: 14) {
                        Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 24)).foregroundStyle(Theme.green).frame(width: 34)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.system(size: 15, weight: .semibold))
                            Text(item.description).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                            Text("\(item.downloads.formatted()) 次下载 · Modrinth").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("选择版本") { project = item }.buttonStyle(SecondaryButton()).disabled(locked)
                    }.padding(18).card()
                }
            }
        }
    }

    @MainActor private func loadInstalled() async {
        guard let target, ["forge", "fabric"].contains(target.loader ?? "") else { mods = []; return }
        loading = true
        defer { loading = false }
        do {
            let result = try await model.modManager.localMods(target)
            guard !Task.isCancelled, self.target?.id == target.id else { return }
            mods = result; localMessage = "共 \(mods.count) 个模组，\(mods.filter(\.enabled).count) 个已启用"
        } catch { if !Task.isCancelled { localMessage = "读取失败：\(error.localizedDescription)" } }
    }
    @MainActor private func search(_ target: InstalledVersion) async {
        guard !searching else { return }
        searching = true; message = "正在搜索 Modrinth…"
        defer { searching = false }
        do {
            let result = try await ModCatalog.search(query.trimmingCharacters(in: .whitespacesAndNewlines), target: target)
            guard self.target?.id == target.id else { return }
            projects = result; message = result.isEmpty ? "没有结果，试试英文名称或项目关键词。" : "找到 \(result.count) 个模组，选择版本后可查看安装内容。"
        } catch { if self.target?.id == target.id { message = "搜索失败：\(error.localizedDescription)" } }
    }
}

private struct ModVersionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: PackProject
    let target: InstalledVersion
    @State private var releases: [ModRelease] = []
    @State private var filter = ""
    @State private var message = "正在读取可用版本…"
    @State private var resolving = false
    @State private var plan: ModInstallPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                PageHeading(title: project.title, subtitle: "安装到 \(target.title) · \(target.gameID) / \(target.loaderLabel)")
                Spacer(); Button("关闭") { dismiss() }.disabled(resolving)
            }
            if let plan {
                Text("将安装以下 \(plan.releases.count) 个模组（含必需依赖）").fontWeight(.semibold)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.releases) { release in
                            HStack { VStack(alignment: .leading, spacing: 5) { Text(release.name).fontWeight(.medium); Text(release.version_number).font(.system(size: 11)).foregroundStyle(Theme.muted) }; Spacer(); Image(systemName: "checkmark.circle").foregroundStyle(Theme.green) }.padding(14).card()
                        }
                    }
                }
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(plan.byteCount), countStyle: .file)) · 同一模组的旧版本会备份后替换。可选依赖不会自动安装。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                Text("按游戏版本和加载器筛选不能保证所有模组组合兼容；服务器有指定版本时，请优先选择该版本。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                HStack {
                    Button("重新选择") { self.plan = nil }
                    Spacer()
                    Button { model.installMods(plan); dismiss() } label: { Text("安装到当前实例").padding(.horizontal, 18).frame(height: 38) }.buttonStyle(PrimaryButton()).disabled(model.busy || model.running || model.authenticating)
                }
            } else {
                TextField("筛选版本，如 2.0.11", text: $filter).textFieldStyle(.roundedBorder)
                HStack { Text(message).font(.system(size: 11)).foregroundStyle(Theme.muted); Spacer(); if resolving { ProgressView().controlSize(.small) } }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(releases.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.version_number.localizedCaseInsensitiveContains(filter) }) { release in
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(release.name).fontWeight(.semibold)
                                    Text("\(release.version_number) · \(release.version_type == "release" ? "正式版" : release.version_type)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Button("检查安装内容") { Task { await prepare(release) } }.buttonStyle(SecondaryButton()).disabled(resolving || model.busy || model.running || model.authenticating)
                            }.padding(14).card()
                        }
                    }
                }
            }
        }
        .padding(26).frame(width: 710, height: 560).background(Theme.background)
        .interactiveDismissDisabled(resolving)
        .task {
            do {
                let result = try await ModCatalog.releases(project.id, target: target)
                guard !Task.isCancelled else { return }
                releases = result; message = result.isEmpty ? "没有适用于当前实例的版本。" : "仅显示当前游戏与加载器可用的版本。"
            } catch { if !Task.isCancelled { message = "读取失败：\(error.localizedDescription)" } }
        }
    }
    @MainActor private func prepare(_ release: ModRelease) async {
        resolving = true; message = "正在检查必需依赖…"
        defer { resolving = false }
        do { plan = try await ModResolver.plan(release, target: target) }
        catch { message = "无法准备：\(error.localizedDescription)" }
    }
}
