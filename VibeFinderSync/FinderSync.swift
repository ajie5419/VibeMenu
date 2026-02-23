import Cocoa
import FinderSync
import OSLog
import Darwin

@objc(FinderSync)
class FinderSync: FIFinderSync {
    private struct Template {
        let title: String
        let ext: String
        let symbolName: String
    }

    private let templates: [Template] = [
        Template(title: "Word 文档", ext: "docx", symbolName: "doc.text"),
        Template(title: "Excel 表格", ext: "xlsx", symbolName: "tablecells"),
        Template(title: "文本文档 (TXT)", ext: "txt", symbolName: "doc.plaintext"),
        Template(title: "Markdown 文档", ext: "md", symbolName: "curlybraces.square")
    ]

    private let logger = Logger(subsystem: "com.xiaojie.VibeMenu.VibeFinderSync", category: "FinderSync")
    private let pwdHomeURL = FinderSync.resolvePwdHomeURL()
    private var fallbackDirectory = FinderSync.resolveDesktopDirectory(defaultHome: FinderSync.resolvePwdHomeURL())
    private let createRequestNotification = "com.xiaojie.VibeMenu.FinderCreateRequest"
    private let requestQueueURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeMenu-create-requests.jsonl", isDirectory: false)
    private let extensionLogURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeMenu-extension.log", isDirectory: false)
    private let maxRequestQueueBytes: UInt64 = 256 * 1024
    private let maxExtensionLogBytes: UInt64 = 512 * 1024

    override init() {
        super.init()
        let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        let desktopURL = FinderSync.resolveDesktopDirectory(defaultHome: pwdHomeURL)
        let documentsURL = FinderSync.resolveDocumentsDirectory(defaultHome: pwdHomeURL)
        let downloadsURL = FinderSync.resolveDownloadsDirectory(defaultHome: pwdHomeURL)
        let homeURL = desktopURL.deletingLastPathComponent()

        fallbackDirectory = desktopURL
        FIFinderSyncController.default().directoryURLs = [
            rootURL,
            homeURL,
            desktopURL,
            documentsURL,
            downloadsURL
        ]
        trace("FinderSync initialized. watching home/desktop/documents/downloads")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        guard menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForItems else {
            return NSMenu(title: "")
        }

        let menu = NSMenu(title: "")
        for (index, template) in templates.enumerated() {
            let item = NSMenuItem(title: "新建 \(template.title)", action: #selector(createFileAction(_:)), keyEquivalent: "")
            if let icon = NSImage(systemSymbolName: template.symbolName, accessibilityDescription: item.title) {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            // Finder Sync 菜单点击回调依赖 responder chain，不能把 target 绑定到扩展实例。
            item.tag = index
            menu.addItem(item)
        }

        return menu
    }

    @IBAction func createFileAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else {
            trace("createFileAction sender is not NSMenuItem")
            return
        }
        guard templates.indices.contains(item.tag) else {
            trace("createFileAction invalid tag=\(item.tag)")
            return
        }
        let ext = templates[item.tag].ext

        let preferredDir = resolveTargetDirectory() ?? fallbackDirectory
        trace("create start: ext=\(ext), preferred=\(preferredDir.path)")

        if let created = createFileIfAllowed(in: preferredDir, ext: ext) {
            trace("create success: \(created.path)")
            return
        }

        trace("extension create failed. delegate to main app, dir=\(preferredDir.path)")
        postCreateRequestToMainApp(ext: ext, directory: preferredDir)

        if preferredDir.path == fallbackDirectory.path {
            return
        }

        if let created = createFileIfAllowed(in: fallbackDirectory, ext: ext) {
            trace("create success(fallback): \(created.path)")
            return
        }

        trace("fallback extension create failed. delegate to main app, dir=\(fallbackDirectory.path)")
        postCreateRequestToMainApp(ext: ext, directory: fallbackDirectory)
    }

    private func resolveTargetDirectory() -> URL? {
        let controller = FIFinderSyncController.default()
        if let targeted = controller.targetedURL() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: targeted.path, isDirectory: &isDir), !isDir.boolValue {
                let resolved = targeted.deletingLastPathComponent()
                return resolved
            }
            return targeted
        }
        if let selected = controller.selectedItemURLs()?.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDir), !isDir.boolValue {
                let resolved = selected.deletingLastPathComponent()
                return resolved
            }
            return selected
        }
        return nil
    }

    private func createFileIfAllowed(in candidate: URL, ext: String) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else {
            trace("createFileIfAllowed invalid dir=\(candidate.path)")
            return nil
        }

        let didStartScope = candidate.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                candidate.stopAccessingSecurityScopedResource()
            }
        }

        let directory = candidate
        let fileURL = makeAvailableURL(in: directory, ext: ext)
        do {
            try Data().write(to: fileURL, options: [])
            return fileURL
        } catch {
            trace("createFileIfAllowed failed: \(fileURL.path), error=\(error.localizedDescription)")
            return nil
        }
    }

    private func postCreateRequestToMainApp(ext: String, directory: URL) {
        let requestID = enqueueCreateRequest(ext: ext, directory: directory)

        let userInfo: [String: String] = [
            "id": requestID,
            "extension": ext,
            "directoryPath": directory.path,
            "time": isoTimestamp()
        ]
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(createRequestNotification),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
        trace("posted create request to main app: id=\(requestID), ext=\(ext), dir=\(directory.path)")
    }

    @discardableResult
    private func enqueueCreateRequest(ext: String, directory: URL) -> String {
        let requestID = UUID().uuidString
        let payload: [String: String] = [
            "id": requestID,
            "extension": ext,
            "directoryPath": directory.path,
            "time": isoTimestamp()
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: json, encoding: .utf8)?.data(using: .utf8) else {
            trace("enqueue create request failed: json encode")
            return requestID
        }
        line.append(0x0A)

        rotateFileIfNeeded(at: requestQueueURL, maxBytes: maxRequestQueueBytes)
        if FileManager.default.fileExists(atPath: requestQueueURL.path),
           let handle = try? FileHandle(forWritingTo: requestQueueURL) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } catch {
                try? handle.close()
                trace("enqueue create request write failed: \(error.localizedDescription)")
            }
        } else {
            do {
                try line.write(to: requestQueueURL, options: .atomic)
            } catch {
                trace("enqueue create request create failed: \(error.localizedDescription)")
            }
        }
        return requestID
    }

    private func makeAvailableURL(in directory: URL, ext: String) -> URL {
        let defaultName = "未命名"
        var result = directory.appendingPathComponent("\(defaultName).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: result.path) {
            result = directory.appendingPathComponent("\(defaultName) \(counter).\(ext)")
            counter += 1
        }
        return result
    }

    private func trace(_ message: String) {
        let line = "[\(isoTimestamp())] \(message)\n"
        logger.log("\(message, privacy: .public)")
        guard let data = line.data(using: .utf8) else { return }
        rotateFileIfNeeded(at: extensionLogURL, maxBytes: maxExtensionLogBytes)
        if FileManager.default.fileExists(atPath: extensionLogURL.path),
           let handle = try? FileHandle(forWritingTo: extensionLogURL) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        } else {
            try? data.write(to: extensionLogURL, options: .atomic)
        }
    }

    private func rotateFileIfNeeded(at fileURL: URL, maxBytes: UInt64) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber else {
            return
        }
        guard size.uint64Value > maxBytes else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            logger.error("rotate file failed: \(fileURL.path, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func resolvePwdHomeURL() -> URL {
        if let pwd = getpwuid(getuid()), let dir = pwd.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private static func resolveDesktopDirectory(defaultHome: URL) -> URL {
        if let desktop = validatedUserDirectory(
            FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ) {
            return desktop
        }
        return defaultHome.appendingPathComponent("Desktop", isDirectory: true)
    }

    private static func resolveDocumentsDirectory(defaultHome: URL) -> URL {
        if let documents = validatedUserDirectory(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ) {
            return documents
        }
        return defaultHome.appendingPathComponent("Documents", isDirectory: true)
    }

    private static func resolveDownloadsDirectory(defaultHome: URL) -> URL {
        if let downloads = validatedUserDirectory(
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ) {
            return downloads
        }
        return defaultHome.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func validatedUserDirectory(_ candidate: URL?) -> URL? {
        guard let candidate else { return nil }
        let sandboxHome = NSHomeDirectory()
        if candidate.path == sandboxHome || candidate.path.hasPrefix(sandboxHome + "/") {
            return nil
        }
        return candidate
    }
}
