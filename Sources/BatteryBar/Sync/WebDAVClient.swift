import Foundation

/// 轻量 WebDAV 客户端，基于 URLSession + XMLParser
final class WebDAVClient {
    let baseURL: URL
    let username: String
    let password: String

    init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    /// 列出目录内容
    func listFiles(at path: String) async throws -> [WebDAVFile] {
        let url = url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.httpBody = propfindBody.data(using: .utf8)
        addAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebDAVError.requestFailed
        }
        return WebDAVResponseParser.parse(data: data, baseURL: baseURL)
    }

    /// 上传数据
    func upload(data: Data, to path: String) async throws {
        let url = url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        addAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebDAVError.uploadFailed
        }
    }

    /// 下载数据
    func download(from path: String) async throws -> Data {
        let url = url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebDAVError.downloadFailed
        }
        return data
    }

    /// 创建目录
    func createFolder(at path: String) async throws {
        let url = url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        addAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebDAVError.requestFailed
        }
    }

    /// 删除文件
    func delete(at path: String) async throws {
        let url = url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebDAVError.requestFailed
        }
    }

    // MARK: - Private

    /// 稳健的 URL 拼接：去掉前导 `/` 后再追加，避免 `appendingPathComponent`
    /// 对已经是 URL 编码或绝对路径形式产生意外结果。
    private func url(for path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(trimmed)
    }

    private func addAuth(_ request: inout URLRequest) {
        let credential = "\(username):\(password)"
        let base64 = Data(credential.utf8).base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
    }

    private var propfindBody: String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:resourcetype/>
            <D:getcontentlength/>
            <D:getlastmodified/>
          </D:prop>
        </D:propfind>
        """
    }
}

struct WebDAVFile {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int
    let modifiedDate: Date?
}

enum WebDAVError: Error {
    case requestFailed
    case uploadFailed
    case downloadFailed
    case parseError
}

/// 简单的 PROPFIND XML 解析
final class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private var files: [WebDAVFile] = []
    private var currentHref: String?
    private var currentIsDir = false
    private var currentSize = 0
    private var currentModified: Date?
    private var currentElement = ""
    private var baseURL: URL?

    static func parse(data: Data, baseURL: URL) -> [WebDAVFile] {
        let parser = XMLParser(data: data)
        let delegate = WebDAVResponseParser()
        delegate.baseURL = baseURL
        parser.delegate = delegate
        // 启用命名空间处理：elementName 将为本地名（无 "D:" 前缀），
        // 避免 WebDAV PROPFIND 响应中的 "D:response" 等带前缀元素名导致比较失败
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.files
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        currentElement = elementName
        switch elementName.lowercased() {
        case "response":
            currentIsDir = false
            currentSize = 0
            currentModified = nil
        // <D:collection/> 是自闭合空元素，foundCharacters 不会被调用，
        // 必须在 didStartElement 中识别
        case "collection":
            currentIsDir = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch currentElement.lowercased() {
        case "href": currentHref = (currentHref ?? "") + trimmed
        case "getcontentlength": currentSize = Int(trimmed) ?? 0
        case "getlastmodified":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            currentModified = formatter.date(from: trimmed)
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName.lowercased() == "response", let href = currentHref {
            let normalizedPath = normalize(href: href)
            let name = normalizedPath.split(separator: "/").last.map(String.init) ?? normalizedPath
            files.append(WebDAVFile(
                path: normalizedPath,
                name: name,
                isDirectory: currentIsDir,
                size: currentSize,
                modifiedDate: currentModified
            ))
            currentHref = nil
        }
    }

    /// 规范化 WebDAV 服务器返回的 href：
    /// - URL decode（处理中文、空格等百分号编码）
    /// - 去掉完整 URL 形式中的 baseURL 前缀
    /// - 去掉绝对路径形式中的 baseURL.path 前缀
    /// - 去掉首尾 `/`
    /// 结果是相对 baseURL 的路径，可直接传回 `WebDAVClient` 的方法使用。
    private func normalize(href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href

        var path = decoded
        if let baseURL = baseURL {
            let baseString = baseURL.absoluteString
            if !baseString.isEmpty, path.hasPrefix(baseString) {
                path = String(path.dropFirst(baseString.count))
            } else {
                let basePath = baseURL.path
                if !basePath.isEmpty, path.hasPrefix(basePath + "/") {
                    path = String(path.dropFirst(basePath.count))
                } else if !basePath.isEmpty, path == basePath {
                    path = ""
                }
            }
        }

        while path.hasPrefix("/") { path = String(path.dropFirst()) }
        while path.hasSuffix("/") { path = String(path.dropLast()) }

        return path
    }
}
