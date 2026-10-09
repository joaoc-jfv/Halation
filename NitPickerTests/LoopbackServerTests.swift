import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import NitPicker

@Suite struct HTTPParsingTests {
    @Test func parsesARequestAndLowercasesHeaderNames() throws {
        let request = try #require(HTTPRequest(head: "GET /abc/seg%20one.m4s?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-9\r\nUser-Agent: AppleCoreMedia"))
        #expect(request.method == "GET")
        #expect(request.path == "/abc/seg one.m4s")
        #expect(request.headers["range"] == "bytes=0-9")
        #expect(request.headers["host"] == "127.0.0.1")
        #expect(request.keepAlive)
    }

    @Test func decidesKeepAliveFromTheVersionAndConnectionHeader() throws {
        #expect(try #require(HTTPRequest(head: "GET / HTTP/1.1\r\nConnection: close")).keepAlive == false)
        #expect(try #require(HTTPRequest(head: "GET / HTTP/1.0")).keepAlive == false)
        #expect(try #require(HTTPRequest(head: "GET / HTTP/1.0\r\nConnection: keep-alive")).keepAlive)
    }

    @Test func rejectsMalformedRequestLines() {
        #expect(HTTPRequest(head: "") == nil)
        #expect(HTTPRequest(head: "GET /") == nil)
        #expect(HTTPRequest(head: "GET / FTP/1.1") == nil)
        #expect(HTTPRequest(head: "GET /%ZZ HTTP/1.1") == nil)
    }
}

@Suite struct ByteRangeTests {
    private func range(_ header: String?, _ length: Int = 100) -> HTTPResponse.ByteRange {
        HTTPResponse.byteRange(header, length: length)
    }

    @Test func parsesTheThreeSingleRangeForms() {
        #expect(range("bytes=10-19") == .satisfiable(10...19))
        #expect(range("bytes=90-") == .satisfiable(90...99))
        #expect(range("bytes=-5") == .satisfiable(95...99))
    }

    @Test func clampsToTheResource() {
        #expect(range("bytes=90-500") == .satisfiable(90...99))
        #expect(range("bytes=-500") == .satisfiable(0...99))
    }

    @Test func flagsUnsatisfiableRanges() {
        #expect(range("bytes=100-") == .unsatisfiable)
        #expect(range("bytes=200-300") == .unsatisfiable)
        #expect(range("bytes=-0") == .unsatisfiable)
        #expect(range("bytes=0-", 0) == .unsatisfiable)
    }

    @Test func ignoresWhatItDoesNotUnderstand() {
        #expect(range(nil) == .none)
        #expect(range("items=0-5") == .none)
        #expect(range("bytes=0-5,10-15") == .none)  // multi-range: send everything
        #expect(range("bytes=9-3") == .none)
        #expect(range("bytes=a-b") == .none)
    }

    @Test func buildsPartialAndHeadResponses() throws {
        let resource = HTTPResource(body: Data((0..<100).map { UInt8($0) }), contentType: "video/mp4")
        let partial = HTTPResponse.make(for: try #require(HTTPRequest(head: "GET /x HTTP/1.1\r\nRange: bytes=10-19")), resource: resource)
        #expect(partial.status == 206)
        #expect(partial.body == Data((10...19).map { UInt8($0) }))
        #expect(partial.headers.contains { $0 == ("Content-Range", "bytes 10-19/100") })
        #expect(partial.headers.contains { $0 == ("Content-Length", "10") })

        let head = HTTPResponse.make(for: try #require(HTTPRequest(head: "HEAD /x HTTP/1.1")), resource: resource)
        #expect(head.status == 200 && head.body.isEmpty)
        #expect(head.headers.contains { $0 == ("Content-Length", "100") })

        let outside = HTTPResponse.make(for: try #require(HTTPRequest(head: "GET /x HTTP/1.1\r\nRange: bytes=500-")), resource: resource)
        #expect(outside.status == 416)
        #expect(outside.headers.contains { $0 == ("Content-Range", "bytes */100") })
    }
}

@Suite struct LoopbackServerTests {
    private let blob = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })

    private func makeServer() throws -> LoopbackServer {
        let blob = blob
        return try LoopbackServer { path in
            switch path {
            case "blob.bin": HTTPResource(body: blob, contentType: "application/octet-stream")
            case "dir/some file.txt": HTTPResource(body: Data("hello".utf8), contentType: "text/plain")
            default: nil
            }
        }
    }

    private func fetch(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    @Test func listensOnTheIPv4LoopbackWithATokenPath() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let base = try await server.start()
        #expect(base.host == "127.0.0.1")
        #expect(base.scheme == "http")
        #expect(base.port != nil && base.port! > 1024)
        let token = base.pathComponents.dropFirst().first ?? ""
        #expect(token.count == 32)
    }

    @Test func servesAResourceWithItsHeaders() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let base = try await server.start()
        let (data, response) = try await fetch(base.appendingPathComponent("blob.bin"))
        #expect(response.statusCode == 200)
        #expect(data == blob)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "\(blob.count)")
    }

    @Test func answersRangeRequests() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent("blob.bin")

        let (middle, response) = try await fetch(url, range: "bytes=1000-1999")
        #expect(response.statusCode == 206)
        #expect(middle == blob.subdata(in: 1000..<2000))
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes 1000-1999/\(blob.count)")

        let (tail, _) = try await fetch(url, range: "bytes=\(blob.count - 10)-")
        #expect(tail == blob.suffix(10))
        let (suffix, _) = try await fetch(url, range: "bytes=-7")
        #expect(suffix == blob.suffix(7))
        let (_, outside) = try await fetch(url, range: "bytes=\(blob.count)-")
        #expect(outside.statusCode == 416)
    }

    @Test func answersHeadWithoutABody() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let (data, response) = try await fetch(try await server.start().appendingPathComponent("blob.bin"), method: "HEAD")
        #expect(response.statusCode == 200)
        #expect(data.isEmpty)
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "\(blob.count)")
    }

    @Test func refusesUnknownPathsWrongTokensAndOtherMethods() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let base = try await server.start()
        #expect(try await fetch(base.appendingPathComponent("missing.bin")).1.statusCode == 404)

        var wrongToken = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        wrongToken.path = "/" + String(repeating: "0", count: 32) + "/blob.bin"
        #expect(try await fetch(wrongToken.url!).1.statusCode == 404)

        var noToken = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        noToken.path = "/blob.bin"
        #expect(try await fetch(noToken.url!).1.statusCode == 404)

        #expect(try await fetch(base.appendingPathComponent("blob.bin"), method: "POST").1.statusCode == 405)
    }

    @Test func decodesPercentEncodedPaths() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let base = try await server.start()
        let (data, response) = try await fetch(URL(string: base.absoluteString + "dir/some%20file.txt")!)
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test func handlesManyConcurrentRequestsWithoutCorruptingThem() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent("blob.bin")
        let expected = SHA256.hash(data: blob)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let range = index % 2 == 0 ? nil : "bytes=\(index * 1000)-\(index * 1000 + 99_999)"
                    let (data, _) = try await self.fetch(url, range: range)
                    if let range {
                        let start = Int(range.dropFirst(6).split(separator: "-")[0])!
                        return data == self.blob.subdata(in: start..<start + 100_000)
                    }
                    return SHA256.hash(data: data) == expected
                }
            }
            for try await ok in group { #expect(ok) }
        }
    }

    @Test func stopsServing() async throws {
        let server = try makeServer()
        let url = try await server.start().appendingPathComponent("blob.bin")
        #expect(try await fetch(url).1.statusCode == 200)
        server.stop()
        try await Task.sleep(for: .milliseconds(150))
        await #expect(throws: (any Error).self) { _ = try await fetch(url) }
    }
}

@MainActor
@Suite struct PlaybackOverLoopbackTests {
    /// The whole point of the server: AVPlayer (through the app's own PlayerModel) plays something it fetches from it.
    @Test func playsAFileServedOverLoopbackWithRangeRequests() async throws {
        let file = try await TestVideo.make(seconds: 3, fps: 10)
        defer { try? FileManager.default.removeItem(at: file) }
        let video = try Data(contentsOf: file)
        let server = try LoopbackServer { path in
            path == "clip.mp4" ? HTTPResource(body: video, contentType: "video/mp4") : nil
        }
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent("clip.mp4")

        let player = PlayerModel(services: .testing())
        defer { player.close() }
        player.open(url)
        await waitUntil("playback over HTTP") { player.state == .playing }
        #expect(player.errorMessage == nil)
        await waitUntil("duration") { player.duration.seconds > 2 }
        #expect(abs(player.duration.seconds - 3) < 0.3)
        #expect(player.mediaInfo?.videoCodec == "H.264")

        player.seek(to: .seconds(2), precise: true)
        await waitUntil("seek") { player.currentTime.seconds >= 2 }
        await waitUntil("the end") { player.state == .ended }
    }
}
