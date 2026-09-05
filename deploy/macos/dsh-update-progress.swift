// dsh-update-progress.swift
// A tiny AppKit progress window shown while `dsh-web-confirm-update.sh` runs
// `npm install -g @deepseek-ai/dsh`. The window reads a status file that the
// script appends to, renders the newest line as live status text, spins an
// indeterminate progress bar, and closes itself when the script writes a
// terminal marker.
//
// Status file line protocol (the script owns the file):
//   STATUS:UPDATE|<text>      in-progress state, spinner runs
//   STATUS:DONE|<text>        finished, spinner stops, beep, auto-close 3s
//   STATUS:ERROR|<text>       failed, spinner stops, stays open for reading
//   <anything else>           shown verbatim as the detail line
//
// Usage: dsh-update-progress <statusFile>
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: dsh-update-progress <statusFile>\n".utf8))
    exit(2)
}
let statusPath = args[1]

func readLastLine(_ path: String) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
    defer { try? handle.close() }
    let data = handle.readDataToEndOfFile()
    guard !data.isEmpty else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    return lines.last.map(String.init)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// ---- window ----
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 520, height: 150),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
window.title = "DeepSeek Harness 更新"
window.isReleasedWhenClosed = false
window.center()

// ---- views ----
let indicator = NSProgressIndicator()
indicator.style = .bar
indicator.isIndeterminate = true
indicator.startAnimation(nil)

let titleLabel = NSTextField(labelWithString: "正在更新官方 dsh ...")
titleLabel.font = .boldSystemFont(ofSize: 15)
titleLabel.lineBreakMode = .byTruncatingTail

let detailLabel = NSTextField(labelWithString: " ")
detailLabel.font = .systemFont(ofSize: 12)
detailLabel.textColor = .secondaryLabelColor
detailLabel.lineBreakMode = .byTruncatingTail
detailLabel.maximumNumberOfLines = 2

let noteLabel = NSTextField(labelWithString: "更新期间请勿关闭本窗口或中断进程")
noteLabel.font = .systemFont(ofSize: 11)
noteLabel.textColor = .tertiaryLabelColor

let stack = NSStackView(views: [titleLabel, indicator, detailLabel, noteLabel])
stack.orientation = .vertical
stack.alignment = .leading
stack.spacing = 8
stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

window.contentView = stack
window.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)

// ---- status polling ----
func parseLine(_ line: String) -> (kind: String, text: String) {
    if line.hasPrefix("STATUS:UPDATE|") { return ("update", String(line.dropFirst("STATUS:UPDATE|".count))) }
    if line.hasPrefix("STATUS:DONE|") { return ("done", String(line.dropFirst("STATUS:DONE|".count))) }
    if line.hasPrefix("STATUS:ERROR|") { return ("error", String(line.dropFirst("STATUS:ERROR|".count))) }
    return ("detail", line)
}

var finished = false

Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
    guard !finished, let line = readLastLine(statusPath) else { return }
    let parsed = parseLine(line)
    switch parsed.kind {
    case "update":
        titleLabel.stringValue = parsed.text
    case "done":
        finished = true
        indicator.stopAnimation(nil)
        titleLabel.stringValue = parsed.text
        titleLabel.textColor = .systemGreen
        noteLabel.stringValue = "更新完成 ✓ 即将重启服务"
        NSSound.beep()
        timer.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
    case "error":
        finished = true
        indicator.stopAnimation(nil)
        titleLabel.stringValue = "更新失败"
        titleLabel.textColor = .systemRed
        detailLabel.stringValue = parsed.text
        noteLabel.stringValue = "请查看 ~/.dsh/autostart-update.log"
        NSSound.beep()
        timer.invalidate()
    case "detail":
        detailLabel.stringValue = parsed.text
    default:
        break
    }
}

app.run()
