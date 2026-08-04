import Testing
import Foundation
@testable import BatteryBar

/// WebDAV PROPFIND 响应解析测试
@Suite struct WebDAVResponseParserTests {

    @Test func parseBasicListing() {
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/BatteryBar/snapshots/</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/BatteryBar/snapshots/2026-07-14.jsonl.gz</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype/>
                <D:getcontentlength>1024</D:getcontentlength>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let data = Data(xml.utf8)
        let baseURL = URL(string: "https://dav.example.com")!
        let files = WebDAVResponseParser.parse(data: data, baseURL: baseURL)

        #expect(files.count == 2)
        #expect(files[0].isDirectory == true)
        #expect(files[1].isDirectory == false)
        #expect(files[1].size == 1024)
    }

    @Test func parseEmptyResponse() {
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
        </D:multistatus>
        """
        let data = Data(xml.utf8)
        let baseURL = URL(string: "https://dav.example.com")!
        let files = WebDAVResponseParser.parse(data: data, baseURL: baseURL)

        #expect(files.isEmpty)
    }

    @Test func stripsBaseURLPathPrefix() {
        // 服务器返回的 href 含 baseURL.path 前缀时，应被规范化去掉
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/BatteryBar/snapshots/2026-07-14.jsonl.gz</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype/>
                <D:getcontentlength>512</D:getcontentlength>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let data = Data(xml.utf8)
        // baseURL.path == "/BatteryBar"，href 应被规范化为 "snapshots/2026-07-14.jsonl.gz"
        let baseURL = URL(string: "https://dav.example.com/BatteryBar")!
        let files = WebDAVResponseParser.parse(data: data, baseURL: baseURL)

        #expect(files.count == 1)
        #expect(files[0].path == "snapshots/2026-07-14.jsonl.gz")
        #expect(files[0].name == "2026-07-14.jsonl.gz")
        #expect(files[0].size == 512)
    }

    @Test func parsesPercentEncodedHref() {
        // 含中文的百分号编码 href，应被 decode
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/BatteryBar/snapshots/%E7%94%B5%E6%B1%A0%E6%95%B0%E6%8D%AE.jsonl</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype/>
                <D:getcontentlength>256</D:getcontentlength>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let data = Data(xml.utf8)
        let baseURL = URL(string: "https://dav.example.com")!
        let files = WebDAVResponseParser.parse(data: data, baseURL: baseURL)

        #expect(files.count == 1)
        #expect(files[0].name.contains("电池数据"))
        #expect(files[0].size == 256)
    }

    @Test func fileWithoutContentSizeHasZeroSize() {
        // 没有 getcontentlength 的条目，size 应为 0
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/BatteryBar/snapshots/unknown.jsonl</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype/>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let data = Data(xml.utf8)
        let baseURL = URL(string: "https://dav.example.com")!
        let files = WebDAVResponseParser.parse(data: data, baseURL: baseURL)

        #expect(files.count == 1)
        #expect(files[0].size == 0)
        #expect(files[0].isDirectory == false)
    }

    @Test func directoryNameFromTrailingSlashHref() {
        // 目录 href 以 `/` 结尾，name 应取最后一段非空路径
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/BatteryBar/snapshots/</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let data = Data(xml.utf8)
        let baseURL = URL(string: "https://dav.example.com")!
        let files = WebDAVResponseParser.parse(data: data, baseURL: baseURL)

        #expect(files.count == 1)
        #expect(files[0].isDirectory == true)
        #expect(files[0].name == "snapshots")
    }
}
