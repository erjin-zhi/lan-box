import Foundation

/// 共享文件夹在磁盘上的所有读写操作。不可变，可在任意线程使用。
struct ShareStore: Sendable {
    let root: URL

    static let originAttribute = "com.lanbox.from"
    static let partPrefix = ".lanbox-"

    init(root: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: 路径解析

    static func components(of relative: String) -> [String]? {
        let comps = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for c in comps where c == "." || c == ".." || c.hasPrefix(".") || c.contains("\0") {
            return nil
        }
        return comps
    }

    /// 将网页请求的相对路径映射到共享文件夹内的 URL，拒绝 “..” 与隐藏文件。
    func resolve(_ relative: String) -> URL? {
        guard let comps = ShareStore.components(of: relative) else { return nil }
        var url = root
        for c in comps { url.appendPathComponent(c) }
        return url
    }

    /// 只有共享文件夹里“真实”的子文件夹可以接收上传——不会穿过替身写进原始文件夹。
    func writableDirectory(_ relative: String) -> URL? {
        guard let comps = ShareStore.components(of: relative) else { return nil }
        var url = root
        for c in comps {
            url.appendPathComponent(c)
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey])
            guard values?.isSymbolicLink == false, values?.isDirectory == true, values?.isPackage != true else { return nil }
        }
        return url
    }

    // MARK: 列表

    struct Entry: Codable {
        enum Kind: String, Codable { case file, folder, package }
        let name: String
        let kind: Kind
        let size: Int64?
        let modified: Date?
        /// 加入共享文件夹的时间（替身按创建替身的时间，而不是原文件的时间）。
        let added: Date?
        let isLink: Bool
        let from: String?
    }

    /// 读条目本身而不跟随替身，得到它被放进文件夹的时间。
    static func addedDate(of url: URL) -> Date? {
        let v = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return v?.addedToDirectoryDate ?? v?.creationDate
    }

    struct Listing: Codable {
        let path: String
        let writable: Bool
        let entries: [Entry]
    }

    func list(_ relative: String) -> Listing? {
        guard let dir = resolve(relative) else { return nil }
        let target = dir.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let names = try? FileManager.default.contentsOfDirectory(atPath: target.path)
        else { return nil }

        var entries: [Entry] = []
        for name in names where !name.hasPrefix(".") {
            let url = target.appendingPathComponent(name)
            let isLink = url.isSymlink
            if isLink && !FileManager.default.fileExists(atPath: url.path) { continue } // 失效的替身直接隐藏
            let resolved = isLink ? url.resolvingSymlinksInPath() : url
            guard let v = try? resolved.resourceValues(forKeys: Set(keys)) else { continue }
            let kind: Entry.Kind = v.isPackage == true ? .package : (v.isDirectory == true ? .folder : .file)
            entries.append(Entry(
                name: name,
                kind: kind,
                size: kind == .file ? Int64(v.fileSize ?? 0) : nil,
                modified: v.contentModificationDate,
                added: ShareStore.addedDate(of: url),
                isLink: isLink,
                from: ShareStore.origin(of: url)
            ))
        }
        // 默认顺序：最新加入的在最前；网页端可以再切换排序方式
        entries.sort { a, b in
            let da = a.added ?? .distantPast, db = b.added ?? .distantPast
            if da != db { return da > db }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let path = (ShareStore.components(of: relative) ?? []).joined(separator: "/")
        return Listing(path: path, writable: writableDirectory(relative) != nil, entries: entries)
    }

    // MARK: 加入文件

    enum AddMode: String, CaseIterable, Identifiable {
        case link, copy
        var id: String { rawValue }
        var title: String { self == .link ? "替身（符号链接）" : "拷贝一份" }
    }

    /// 把 Finder 拖入的项目加入共享根目录。返回实际创建的条目。
    @discardableResult
    func add(_ sources: [URL], mode: AddMode) -> [URL] {
        var created: [URL] = []
        for source in sources {
            let src = source.standardizedFileURL
            let resolved = src.resolvingSymlinksInPath()
            // 已经在共享文件夹里 / 是共享文件夹本身或其上级：跳过
            if src.deletingLastPathComponent().resolvingSymlinksInPath() == root { continue }
            if root.path == resolved.path || root.path.hasPrefix(resolved.path + "/") { continue }

            let dest = uniqueURL(in: root, name: src.lastPathComponent)
            do {
                switch mode {
                case .link: try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: resolved)
                case .copy: try FileManager.default.copyItem(at: resolved, to: dest)
                }
                created.append(dest)
            } catch {
                NSLog("LanBox: 无法加入 \(src.path): \(error)")
            }
        }
        return created
    }

    func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) || candidate.isSymlink else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        repeat {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = dir.appendingPathComponent(n)
            i += 1
        } while fm.fileExists(atPath: candidate.path) || candidate.isSymlink
        return candidate
    }

    // MARK: 来源标记

    static func origin(of url: URL) -> String? {
        let size = getxattr(url.path, originAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, originAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0 else { return nil }
        return String(data: data.prefix(read), encoding: .utf8)
    }

    static func setOrigin(_ name: String, for url: URL) {
        let data = Data(name.utf8)
        _ = data.withUnsafeBytes { setxattr(url.path, originAttribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
    }

    /// 文件夹的大致总字节数，用于估算打包下载进度。
    static func totalSize(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
