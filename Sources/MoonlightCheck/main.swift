import Foundation
import MoonlightCore

@main
struct IntegrationCheck {
    static func main() async {
        setbuf(stdout, nil)
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { print("Usage: MoonlightCheck ROOT VERSION [--loader fabric|forge BUILD] [--pack PATH] [--launch]"); exit(2) }
            let root = URL(fileURLWithPath: args[1])
            let installer = Installer(root: root)
            let report: @Sendable (InstallProgress) async -> Void = { print("\(Int($0.fraction * 100))% \($0.message)") }
            let installed: InstalledVersion
            if args.contains("--catalog") {
                let hits = try await PackCatalog.search("Fabulously", game: "1.21.1", loader: "fabric")
                guard hits.contains(where: { $0.slug == "fabulously-optimized" }) else { throw LauncherError("Catalog search missing expected project") }
                print("CATALOG_OK \(hits.count) projects")
            }
            if let flag = args.firstIndex(of: "--modrinth"), args.count > flag + 1 {
                let releases = try await PackCatalog.releases(args[flag + 1])
                guard let release = releases.first(where: { $0.supported && $0.game_versions.contains(args[2]) }) else { throw LauncherError("No compatible pack release") }
                print("PACK_RELEASE \(release.name)")
                installed = try await installer.installPack(release, progress: report)
            } else if let flag = args.firstIndex(of: "--pack"), args.count > flag + 1 {
                installed = try await installer.importPack(URL(fileURLWithPath: args[flag + 1]), progress: report)
            } else if let existing = await installer.installed().first(where: { $0.id == args[2] }), args.contains("--existing") {
                if args.contains("--repair") { installed = try await installer.repairEnvironment(existing, progress: report) }
                else { installed = existing }
            } else {
                let manifest = try await installer.manifest()
                guard let version = manifest.versions.first(where: { $0.id == args[2] }) else { throw LauncherError("Version missing") }
                if let flag = args.firstIndex(of: "--loader"), args.count > flag + 2 {
                    installed = try await installer.installLoader(version, loader: args[flag + 1], build: args[flag + 2], progress: report)
                } else { installed = try await installer.install(version, progress: report) }
            }
            let plan = try await installer.launchPlan(installed, username: "MoonlightTest", memoryMB: args.contains("--pack") || installed.displayName != nil ? 6144 : 2048, demo: false) { print($0.message) }
            print("INSTALL_OK \(installed.id) \(plan.executable.path)")
            if args.contains("--launch") {
                let log = root.appendingPathComponent("integration-game.log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close() }
                let process = Process()
                process.executableURL = plan.executable; process.arguments = plan.arguments
                process.currentDirectoryURL = plan.directory
                process.standardOutput = handle; process.standardError = handle
                try process.run()
                defer { if process.isRunning { process.terminate() } }
                for _ in 0..<300 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard process.isRunning else { throw LauncherError("Game exited: \(process.terminationStatus). See \(log.path)") }
                    let text = (try? String(contentsOf: log)) ?? ""
                    if text.contains("OpenAL initialized") || text.contains("Sound engine started") {
                        print("GAME_RUNNING pid=\(process.processIdentifier). Check the Minecraft window. Log: \(log.path)")
                        // Keep the game available briefly for visual verification, then end the test.
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        process.terminate(); process.waitUntilExit()
                        print("LAUNCH_OK")
                        return
                    }
                }
                process.terminate(); process.waitUntilExit()
                throw LauncherError("Game started but readiness was not observed within 300 seconds. See \(log.path)")
            }
        } catch { print("CHECK_FAILED: \(error.localizedDescription)"); exit(1) }
    }
}
