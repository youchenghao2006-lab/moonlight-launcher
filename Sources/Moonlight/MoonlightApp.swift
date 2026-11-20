import SwiftUI
import AppKit

@main
struct MoonlightApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Moonlight") {
            ContentView().environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.light)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("打开游戏目录") { model.openFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
