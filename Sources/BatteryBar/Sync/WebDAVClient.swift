import Foundation

protocol WebDAVClientProtocol: Sendable {
    func listFiles(at path: String) async throws -> [WebDAVFile]
    func upload(data: Data, to path: String) async throws
    func download(from path: String) async throws -> Data
    func createFolder(at path: String) async throws
}

/// 轻量 WebDAV 客户端，基于 URLSession + XMLParser
final class WebDAVClient: WebDAVClientProtocol, @unchecked Sendable {
    /// PROPFIND 只应返回当前目录；超过 2 MiB 基本可判定为错误配置或恶意响应。
    static let maximumListingBytes = 2 * 1_024 * 1_024
    /// 单个同步对象的压缩/JSON 文件上限。解压后还有独立上限。
    static let maximumDownloadBytes = 8 * 1_024 * 1_024

    private static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(
            configuration: configuration,
            delegate: WebDAVRedirectPolicyDelegate(),
            delegateQueue: nil
        )
    }()

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
        let url = try url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.httpBody = propfindBody.data(using: .utf8)
        addAuth(&request)

        let data = try await boundedResponseData(for: request, maximumBytes: Self.maximumListingBytes)
        return try WebDAVResponseParser.parseValidated(data: data, baseURL: baseURL)
    }

    /// 上传数据
    func upload(data: Data, to path: String) async throws {
        let url = try url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        addAuth(&request)

        try await performRequest(request)
    }

    /// 下载数据
    func download(from path: String) async throws -> Data {
        let url = try url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuth(&request)

        return try await boundedResponseData(for: request, maximumBytes: Self.maximumDownloadBytes)
    }

    /// 创建目录
    func createFolder(at path: String) async throws {
        let url = try url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        addAuth(&request)

        do {
            try await performRequest(request)
        } catch WebDAVError.httpStatus(405) {
            // 多数 WebDAV 服务以 405 表示 MKCOL 目标已存在，属于幂等成功。
        }
    }

    /// 删除文件
    func delete(at path: String) async throws {
        let url = try url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuth(&request)

        try await performRequest(request)
    }

    // MARK: - Private

    /// 稳健的 URL 拼接：去掉前导 `/` 后再追加，避免 `appendingPathComponent`
    /// 对已经是 URL 编码或绝对路径形式产生意外结果。
    private func url(for path: String) throws -> URL {
        try WebDAVEndpointPolicy.validate(baseURL)
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(trimmed)
    }

    private func addAuth(_ request: inout URLRequest) {
        let credential = "\(username):\(password)"
        let base64 = Data(credential.utf8).base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
    }

    /// 使用下载任务把响应先落到 URLSession 临时文件，再检查大小后读入内存；
    /// 避免 `data(for:)` 在校验 Content-Length 前已经分配任意大的响应。
    private func boundedResponseData(for request: URLRequest, maximumBytes: Int) async throws -> Data {
        let (temporaryURL, response) = try await Self.secureSession.download(for: request)
        let http = try validatedHTTPResponse(response)
        if http.expectedContentLength > Int64(maximumBytes) {
            throw WebDAVError.responseTooLarge
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maximumBytes else { throw WebDAVError.responseTooLarge }
        return try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
    }

    /// 对无需响应体的写请求同样使用 download task，避免恶意服务器返回巨大 body。
    private func performRequest(_ request: URLRequest) async throws {
        let (_, response) = try await Self.secureSession.download(for: request)
        _ = try validatedHTTPResponse(response)
    }

    private func validatedHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.requestFailed }
        switch http.statusCode {
        case 200...299: return http
        case 404: throw WebDAVError.notFound
        default: throw WebDAVError.httpStatus(http.statusCode)
        }
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

/// URLSession 默认会跟随重定向；初始 HTTPS 地址若被降级到 HTTP，也必须在发送下一跳
/// 请求前拦截，不能只验证用户输入的首个 URL。
private final class WebDAVRedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let redirectedURL = request.url,
              WebDAVEndpointPolicy.allowsRedirect(from: originalURL, to: redirectedURL)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct WebDAVFile: Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int
    let modifiedDate: Date?
}

/// WebDAV 使用 Basic Auth，非 TLS 连接会把可还原的凭据暴露在链路上。
/// 仅允许 HTTPS；HTTP 只对本机回环地址开放，便于本地开发和隔离测试。
enum WebDAVEndpointPolicy {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty
        else { throw WebDAVError.invalidURL }

        if scheme == "https" { return }
        if scheme == "http", loopbackHosts.contains(host) { return }
        throw WebDAVError.insecureTransport
    }

    /// Basic Auth 重定向只允许同源，避免 HTTPS 请求把凭据带到另一个主机或端口。
    static func allowsRedirect(from source: URL, to destination: URL) -> Bool {
        guard (try? validate(destination)) != nil,
              source.scheme?.lowercased() == destination.scheme?.lowercased(),
              source.host?.lowercased() == destination.host?.lowercased(),
              effectivePort(of: source) == effectivePort(of: destination)
        else { return false }
        return true
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

enum WebDAVError: Error, LocalizedError, Equatable {
    case invalidURL
    case insecureTransport
    case notFound
    case httpStatus(Int)
    case responseTooLarge
    case decompressedDataTooLarge
    case tooManyEntries
    case requestFailed
    case uploadFailed
    case downloadFailed
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL: "服务器地址无效"
        case .insecureTransport: "WebDAV 仅允许 HTTPS（本机 localhost 可使用 HTTP）"
        case .notFound: "WebDAV 目标不存在"
        case .httpStatus(let status): "WebDAV 请求失败（HTTP \(status)）"
        case .responseTooLarge: "WebDAV 响应超过安全大小限制"
        case .decompressedDataTooLarge: "WebDAV 压缩数据解压后超过安全限制"
        case .tooManyEntries: "WebDAV 返回的设备或文件数量超过安全限制"
        case .requestFailed: "WebDAV 请求失败"
        case .uploadFailed: "WebDAV 上传失败"
        case .downloadFailed: "WebDAV 下载失败"
        case .parseError: "WebDAV 响应无法解析"
        }
    }
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
        (try? parseValidated(data: data, baseURL: baseURL)) ?? []
    }

    static func parseValidated(data: Data, baseURL: URL) throws -> [WebDAVFile] {
        let parser = XMLParser(data: data)
        let delegate = WebDAVResponseParser()
        delegate.baseURL = baseURL
        parser.delegate = delegate
        // 启用命名空间处理：elementName 将为本地名（无 "D:" 前缀），
        // 避免 WebDAV PROPFIND 响应中的 "D:response" 等带前缀元素名导致比较失败
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw WebDAVError.parseError }
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
