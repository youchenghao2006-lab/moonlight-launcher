import SwiftUI
import AppKit
import MoonlightCore

struct AccountSettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("游戏身份与登录", systemImage: "person.crop.circle").font(.system(size: 15, weight: .semibold))
            Picker("启动模式", selection: Binding(get: { model.preferences.authenticationMode }, set: { model.setAuthenticationMode($0) })) {
                Text("离线单人").tag("offline"); Text("微软正版").tag("online"); Text("官方试玩").tag("demo")
            }.pickerStyle(.segmented)
            if model.preferences.authenticationMode == "online" {
                Text("登录拥有 Minecraft Java 版资格的微软账号，启动时联网验证身份，可用于需要正版验证的服务器。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if model.accounts.isEmpty { Text("还没有添加正版账号。").foregroundStyle(Theme.muted) }
            } else {
                HStack { Text("游戏名称"); Spacer(); TextField("Player", text: $model.preferences.username).textFieldStyle(.roundedBorder).frame(width: 220) }
                Text(model.preferences.authenticationMode == "demo" ? "启动 Minecraft 自带的限时试玩世界。" : "本地名称使用 3–16 位英文字母、数字或下划线；离线模式无法加入需要正版验证的服务器。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !model.accounts.isEmpty {
                Divider()
                ForEach(model.accounts) { account in
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.square.fill").font(.system(size: 25)).foregroundStyle(Theme.green)
                        VStack(alignment: .leading, spacing: 5) { Text(account.name).fontWeight(.semibold); Text("微软正版账号").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                        Spacer()
                        let current = model.preferences.authenticationMode == "online" && model.preferences.onlineAccount == account.id
                        Button(current ? "当前账号" : "使用此账号") { model.useAccount(account) }.buttonStyle(SecondaryButton()).disabled(current)
                        Button("退出登录") { model.removeAccount(account) }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                    }
                }
            }
            Divider()
            HStack {
                Button { model.login() } label: { Label(model.authenticationConfigured ? "添加微软账号" : "配置微软登录", systemImage: "person.badge.plus") }.buttonStyle(SecondaryButton())
                Spacer()
                if model.authenticating { ProgressView().controlSize(.small) }
                Button("应用配置…") { model.configurationSheet = true }.buttonStyle(.plain).foregroundStyle(Theme.green)
            }
            Text(model.authenticationConfigured ? "授权在微软网页完成。月光不接触密码，登录凭证仅保存在本机 macOS 钥匙串中。应用编号已配置，是否获准访问 Minecraft 会在登录时检查。" : "还需为月光配置自己的微软应用编号，并申请 Minecraft 接口访问许可。当前离线模式可正常使用。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(23).card().disabled(model.busy || model.running || model.authenticating)
    }
}

struct MicrosoftLoginSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "登录微软正版账号", subtitle: "请在微软官方网页完成登录与授权。")
            if let challenge = model.loginChallenge {
                VStack(alignment: .leading, spacing: 14) {
                    Text("在网页输入此登录码").foregroundStyle(Theme.muted)
                    Text(challenge.userCode).font(.system(size: 32, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("复制登录码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(challenge.userCode, forType: .string) }
                        Button("打开微软登录页") { NSWorkspace.shared.open(challenge.verificationURL) }.buttonStyle(SecondaryButton())
                    }
                    Text("有效期至 \(challenge.expiresAt.formatted(date: .omitted, time: .shortened))。完成授权后无需粘贴任何令牌，月光会自动继续。")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }.padding(20).card()
            }
            HStack { if model.authenticating { ProgressView().controlSize(.small) }; Text(model.loginStatus).font(.system(size: 12)) }
            if let error = model.loginError { Text(error).foregroundStyle(.red).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
            Text("登录成功后会切换到正版模式，并将可续期的登录凭证保存到本机钥匙串；可在设置里退出登录。请确认微软网页显示的授权应用是你为月光配置的应用。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if !model.authenticating { Button("重试") { model.login() }.buttonStyle(SecondaryButton()) }
                Button(model.authenticating ? "取消登录" : "关闭") { model.cancelLogin() }
            }
        }.padding(28).frame(width: 570).background(Theme.background)
    }
}

struct MicrosoftConfigurationSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var draft = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "配置月光的微软登录", subtitle: "这一步配置启动器应用，之后再登录你的游戏账号。")
            Text("1. 为月光注册支持个人微软账号的公共客户端应用。\n2. 开启「允许公共客户端流」，并申请 Minecraft Java 游戏服务 API 访问许可。\n3. 将获准应用的 Client ID 填在下面。")
                .lineSpacing(7).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            TextField("应用 Client ID（公开编号，不是密码）", text: $draft).textFieldStyle(.roundedBorder)
            Text("示例格式：xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\n不需要客户端密钥，也不要填写账号密码或登录令牌。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button("查看完整配置说明") {
                    if let file = Bundle.main.url(forResource: "MicrosoftLoginSetup", withExtension: "html") { NSWorkspace.shared.open(file) }
                    else { NSWorkspace.shared.open(URL(string: "https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app")!) }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存配置") {
                    do { model.preferences.microsoftClientID = try MicrosoftConfiguration.validate(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(SecondaryButton())
            }
        }.padding(28).frame(width: 620).background(Theme.background)
        .onAppear { draft = model.clientID }
    }
}
