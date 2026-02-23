import SwiftUI
import AppKit

@main
struct VibeMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    private let finderSyncGuideShownKey = "FinderSyncGuideShown"
    private let createRequestNotification = "com.xiaojie.VibeMenu.FinderCreateRequest"
    private let debugLogURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("VibeMenu-debug.log", isDirectory: false)
    private let extensionDebugLogURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Containers/com.xiaojie.VibeMenu.VibeFinderSync/Data/tmp/VibeMenu-extension.log", isDirectory: false)
    private let extensionRequestQueueURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Containers/com.xiaojie.VibeMenu.VibeFinderSync/Data/tmp/VibeMenu-create-requests.jsonl", isDirectory: false)
    private var requestPollTimer: Timer?
    private var requestQueueOffset: UInt64 = 0
    private var processedRequestIDs = Set<String>()
    private var processedRequestOrder = [String]()
    private let maxProcessedRequestIDs = 400

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "新建文档")
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleFinderCreateRequest(_:)),
            name: Notification.Name(createRequestNotification),
            object: nil
        )
        setupMenu()
        showFinderSyncGuideIfNeeded()
        startRequestQueuePolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        requestPollTimer?.invalidate()
        requestPollTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    func setupMenu() {
        let menu = NSMenu()
        let formats = [
            ("Markdown 文档", "md"),
            ("文本文档", "txt"),
            ("Word 文档", "docx"),
            ("Excel 表格", "xlsx")
        ]
        for (name, ext) in formats {
            let item = NSMenuItem(title: "新建 \(name)", action: #selector(createFile(_:)), keyEquivalent: "")
            item.representedObject = ext
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "开启 Finder 右键菜单…", action: #selector(openFinderExtensionSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出 VibeMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func openFinderExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.FinderSync",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Extensions"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    @objc func openDebugLog() {
        if !FileManager.default.fileExists(atPath: debugLogURL.path) {
            let content = "VibeMenu debug log\n".data(using: .utf8) ?? Data()
            FileManager.default.createFile(atPath: debugLogURL.path, contents: content, attributes: nil)
        }
        NSWorkspace.shared.open(debugLogURL)
    }

    @objc func openExtensionDebugLog() {
        if !FileManager.default.fileExists(atPath: extensionDebugLogURL.path) {
            let content = "VibeFinderSync extension log\n".data(using: .utf8) ?? Data()
            FileManager.default.createFile(atPath: extensionDebugLogURL.path, contents: content, attributes: nil)
        }
        NSWorkspace.shared.open(extensionDebugLogURL)
    }

    private func showFinderSyncGuideIfNeeded() {
        if UserDefaults.standard.bool(forKey: finderSyncGuideShownKey) {
            return
        }

        UserDefaults.standard.set(true, forKey: finderSyncGuideShownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.presentFinderSyncGuideAlert()
        }
    }

    private func presentFinderSyncGuideAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "开启 Finder 右键菜单"
        alert.informativeText = "请在“系统设置 -> 隐私与安全性 -> 扩展程序 -> 访达”里开启 VibeFinderSync。开启后可在 Finder 右键菜单使用“新建文档”。"
        alert.addButton(withTitle: "打开扩展设置")
        alert.addButton(withTitle: "稍后")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openFinderExtensionSettings()
        }
    }
    
    @objc func createFile(_ sender: NSMenuItem) {
        guard let ext = sender.representedObject as? String else { return }
        
        let scriptSource = """
        tell application "Finder"
            try
                set currentFolder to (folder of the front window as alias)
            on error
                set currentFolder to (path to desktop folder as alias)
            end try
            return POSIX path of currentFolder
        end tell
        """
        
        var errorDict: NSDictionary?
        if let scriptObject = NSAppleScript(source: scriptSource) {
            let resultDescriptor = scriptObject.executeAndReturnError(&errorDict)
            if let output = resultDescriptor.stringValue {
                let targetDir = URL(fileURLWithPath: output)
                _ = createFile(in: targetDir, ext: ext)
            } else if let error = errorDict {
                print("AppleScript Error: \(error)")
            }
        }
    }

    @objc private func handleFinderCreateRequest(_ notification: Notification) {
        guard let userInfo = notification.userInfo as? [String: String] else { return }
        guard let ext = userInfo["extension"], !ext.isEmpty else { return }
        let directoryPath = userInfo["directoryPath"] ?? NSHomeDirectory()
        let requestID = userInfo["id"] ?? "dist-\(UUID().uuidString)"
        guard markRequestIfNeeded(requestID) else { return }
        handleCreateRequest(ext: ext, directoryPath: directoryPath, source: "distributed", requestID: requestID)
    }

    private func createFile(in targetDir: URL, ext: String) -> URL? {
        let fallbackDir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Desktop", isDirectory: true)
        let directory = writableDirectory(from: targetDir) ?? fallbackDir

        let defaultName = "未命名"
        var finalURL = directory.appendingPathComponent("\(defaultName).\(ext)")
        var counter = 1

        while FileManager.default.fileExists(atPath: finalURL.path) {
            finalURL = directory.appendingPathComponent("\(defaultName) \(counter).\(ext)")
            counter += 1
        }

        do {
            try Data().write(to: finalURL, options: [])
            return finalURL
        } catch {
            return nil
        }
    }

    private func writableDirectory(from directory: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            return nil
        }
        return directory
    }

    private func appendDebugLog(_ message: String) {
        let line = "[\(isoTimestamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: debugLogURL.path),
           let handle = try? FileHandle(forWritingTo: debugLogURL) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        } else {
            try? data.write(to: debugLogURL, options: .atomic)
        }
    }

    private func startRequestQueuePolling() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: extensionRequestQueueURL.path),
           let size = attrs[.size] as? NSNumber {
            requestQueueOffset = size.uint64Value
        } else {
            requestQueueOffset = 0
        }
        appendDebugLog("request queue polling started: \(extensionRequestQueueURL.path), offset=\(requestQueueOffset)")
        requestPollTimer?.invalidate()
        requestPollTimer = Timer.scheduledTimer(
            timeInterval: 0.8,
            target: self,
            selector: #selector(pollCreateRequestQueue),
            userInfo: nil,
            repeats: true
        )
        requestPollTimer?.tolerance = 0.3
    }

    @objc private func pollCreateRequestQueue() {
        guard FileManager.default.fileExists(atPath: extensionRequestQueueURL.path) else { return }

        do {
            let handle = try FileHandle(forReadingFrom: extensionRequestQueueURL)
            defer { try? handle.close() }

            let endOffset = try handle.seekToEnd()
            if requestQueueOffset > endOffset {
                requestQueueOffset = 0
            }

            try handle.seek(toOffset: requestQueueOffset)
            let chunk = try handle.readToEnd() ?? Data()
            requestQueueOffset = endOffset
            guard !chunk.isEmpty else { return }
            guard let text = String(data: chunk, encoding: .utf8) else {
                appendDebugLog("request queue decode failed")
                return
            }

            for line in text.split(separator: "\n") {
                handleQueueLine(String(line))
            }
        } catch {
            appendDebugLog("request queue poll failed: \(error.localizedDescription)")
        }
    }

    private func handleQueueLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let ext = payload["extension"], !ext.isEmpty else {
            return
        }

        let directoryPath = payload["directoryPath"] ?? NSHomeDirectory()
        let requestID = payload["id"] ?? "queue-\(UUID().uuidString)"
        guard markRequestIfNeeded(requestID) else { return }
        handleCreateRequest(ext: ext, directoryPath: directoryPath, source: "queue", requestID: requestID)
    }

    private func handleCreateRequest(ext: String, directoryPath: String, source: String, requestID: String) {
        let targetDir = URL(fileURLWithPath: directoryPath, isDirectory: true)
        appendDebugLog("\(source) request received. id=\(requestID) dir=\(targetDir.path) ext=\(ext)")
        if let createdURL = createFile(in: targetDir, ext: ext) {
            appendDebugLog("main app created via \(source) request. id=\(requestID) path=\(createdURL.path)")
        } else {
            appendDebugLog("main app create failed via \(source) request. id=\(requestID) dir=\(targetDir.path) ext=\(ext)")
        }
    }

    private func markRequestIfNeeded(_ requestID: String) -> Bool {
        if processedRequestIDs.contains(requestID) {
            return false
        }
        processedRequestIDs.insert(requestID)
        processedRequestOrder.append(requestID)
        if processedRequestOrder.count > maxProcessedRequestIDs {
            let overflow = processedRequestOrder.count - maxProcessedRequestIDs
            for _ in 0..<overflow {
                let removed = processedRequestOrder.removeFirst()
                processedRequestIDs.remove(removed)
            }
        }
        return true
    }

    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
