// dsh-web-unlock-watcher
// Runs as a persistent LaunchAgent. It waits for the screen to unlock (or the
// user session to become active / the machine to wake) and then runs
// ~/.dsh/bin/dsh-web-unlock.sh, which checks the official @deepseek-ai/dsh
// release and restarts the web UI only when a newer version is published.
//
// macOS rarely reboots, so this gives the "every boot" freshness Windows gets
// from its Startup autostart, at every screen unlock instead.
import AppKit
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let scriptPath = home + "/.dsh/bin/dsh-web-unlock.sh"

var lastRun = Date.distantPast
func runSyncScript() {
    // Debounce: an unlock often fires several notifications at once
    // (screenIsUnlocked + sessionDidBecomeActive + didWake).
    let now = Date()
    guard now.timeIntervalSince(lastRun) > 5 else { return }
    lastRun = now

    guard FileManager.default.isExecutableFile(atPath: scriptPath) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptPath]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        NSLog("dsh-web-unlock-watcher: failed to run sync script: \(error)")
    }
}

var observers: [NSObjectProtocol] = []

func observe(_ name: Notification.Name, center: NotificationCenter) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
        runSyncScript()
    }
    observers.append(token)
}

// One pass at startup covers login, and doubles as a smoke test.
runSyncScript()

let workspaceCenter = NSWorkspace.shared.notificationCenter
observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspaceCenter)
observe(NSWorkspace.didWakeNotification, center: workspaceCenter)

// loginwindow posts this distributed notification when the screen unlocks.
let distributedCenter = DistributedNotificationCenter.default()
observe(Notification.Name("com.apple.screenIsUnlocked"), center: distributedCenter)

// Connect to the GUI session so workspace/session notifications arrive, and
// stay alive forever.
_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.prohibited)
RunLoop.main.run()
