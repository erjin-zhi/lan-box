import Foundation
import UniformTypeIdentifiers

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // 键名统一小写
    let cookies: [String: String]

    var contentLength: Int64? { headers["content-length"].flatMap { Int64($0) } }
    var userAgent: String { headers["user-agent"] ?? "" }

    static func parse(_ head: Data) -> HTTPRequest? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let decode: (Substring) -> String = {
                    String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                }
                query[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
            }
        }

        var cookies: [String: String] = [:]
        for pair in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { cookies[kv[0].trimmingCharacters(in: .whitespaces)] = String(kv[1]) }
        }

        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers, cookies: cookies)
    }
}

struct HTTPHead {
    var status: Int
    var headers: [(String, String)] = []

    init(_ status: Int, _ headers: [(String, String)] = []) {
        self.status = status
        self.headers = headers
    }

    mutating func add(_ name: String, _ value: String) { headers.append((name, value)) }

    func serialized() -> Data {
        var s = "HTTP/1.1 \(status) \(HTTPHead.reason(status))\r\n"
        var names = Set<String>()
        for (k, v) in headers {
            s += "\(k): \(v)\r\n"
            names.insert(k.lowercased())
        }
        if !names.contains("connection") { s += "Connection: close\r\n" }
        s += "Server: LanBox\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n"
        return Data(s.utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        case 507: return "Insufficient Storage"
        default: return "Status"
        }
    }
}

enum MIME {
    static func type(for url: URL) -> String {
        if let t = UTType(filenameExtension: url.pathExtension), let mime = t.preferredMIMEType { return mime }
        return "application/octet-stream"
    }

    /// 可以在浏览器内直接打开且不会执行脚本的类型。
    static func isSafeInline(_ mime: String) -> Bool {
        if mime == "image/svg+xml" { return false }
        return mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/")
            || mime == "application/pdf" || mime == "text/plain"
    }

    static func contentDisposition(_ kind: String, filename: String) -> String {
        let ascii = filename.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" ? String($0) : "_" }.joined()
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ascii
        return "\(kind); filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
    }
}

extension Encodable {
    func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}
