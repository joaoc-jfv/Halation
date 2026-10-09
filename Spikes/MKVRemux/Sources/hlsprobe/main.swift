import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Network

// hlsprobe <dir with init.mp4, seg_*.m4s, segments.txt> <http|loader> [--master] [--seek SECONDS] [--timeout SECONDS]
//
// Publishes the pieces as a VOD HLS stream and plays it with a headless AVPlayer, to find out whether
//   * AVPlayer accepts it at all, over a loopback HTTP server or an AVAssetResourceLoader (custom scheme)
//   * the video really decodes (frames are pulled through an AVPlayerItemVideoOutput) and with which colour tags
//   * the Dolby Vision and E-AC-3 JOC sample entries survive
//   * seeking inside the playlist works

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let index = args.firstIndex(of: name) else { return false }
    args.remove(at: index)
    return true
}
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}
let useMaster = flag("--master")
let redirectAll = flag("--redirect-all")  // loader mode: redirect the playlists too (they are written next to the segments)
let redirectToFiles = flag("--redirect-file") || redirectAll  // loader mode: answer segment requests with a redirect to a file:// URL
let seekTarget = option("--seek").flatMap(Double.init)
let timeout = option("--timeout").flatMap(Double.init) ?? 25
let playUntil = option("--until").flatMap(Double.init)  // keep playing until the clock reaches this
guard args.count == 2, ["http", "loader"].contains(args[1]) else {
    print("usage: hlsprobe <dir> <http|loader> [--master] [--seek S] [--timeout S]")
    exit(2)
}
let directory = URL(fileURLWithPath: args[0], isDirectory: true)
let mode = args[1]

func log(_ text: String) { print(String(format: "[%6.2f] ", Date().timeIntervalSince(startedAt)) + text); fflush(stdout) }
let startedAt = Date()

// MARK: Playlists

struct Segment { var name: String; var duration: Double }
let segments: [Segment] = try String(contentsOf: directory.appendingPathComponent("segments.txt"), encoding: .utf8)
    .split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ")
        guard parts.count >= 3, let duration = parts.first(where: { $0.hasPrefix("duration=") }).flatMap({ Double($0.dropFirst(9)) }) else { return nil }
        return Segment(name: String(parts[0]), duration: duration)
    }
let initData = try Data(contentsOf: directory.appendingPathComponent("init.mp4"))

/// The `hvc1.…` codec string, from the hvcC record in the init segment.
func hevcCodecString(_ data: Data) -> String? {
    guard let range = data.range(of: Data("hvcC".utf8)) else { return nil }
    let record = [UInt8](data[range.upperBound..<min(range.upperBound + 13, data.count)])
    guard record.count >= 13 else { return nil }
    let profile = Int(record[1] & 0x1F), tier = (record[1] >> 5) & 1 == 1 ? "H" : "L"
    var compat = UInt32(record[2]) << 24 | UInt32(record[3]) << 16 | UInt32(record[4]) << 8 | UInt32(record[5])
    var reversed: UInt32 = 0
    for _ in 0..<32 { reversed = reversed << 1 | (compat & 1); compat >>= 1 }
    let constraints = record[6..<12].reversed().drop { $0 == 0 }.reversed().map { String(format: "%X", $0) }.joined(separator: ".")
    return "hvc1.\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(record[12]).\(constraints.isEmpty ? "0" : constraints)"
}
/// `dvh1.08.06`, from the dvvC record.
func dolbyVisionCodecString(_ data: Data) -> String? {
    guard let range = data.range(of: Data("dvvC".utf8)) else { return nil }
    let record = [UInt8](data[range.upperBound..<min(range.upperBound + 5, data.count)])
    guard record.count >= 5 else { return nil }
    let profile = Int(record[2] >> 1), level = Int(record[2] & 1) << 5 | Int(record[3] >> 3)
    return String(format: "dvh1.%02d.%02d", profile, level)
}

let totalDuration = segments.reduce(0) { $0 + $1.duration }
var mediaPlaylist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(segments.map(\.duration).max() ?? 4)))\n"
mediaPlaylist += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
for segment in segments { mediaPlaylist += String(format: "#EXTINF:%.3f,\n%@\n", segment.duration, segment.name) }
mediaPlaylist += "#EXT-X-ENDLIST\n"

var masterPlaylist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
let hevc = hevcCodecString(initData) ?? "hvc1.2.4.H150.B0"
let dolby = dolbyVisionCodecString(initData)
masterPlaylist += "#EXT-X-STREAM-INF:BANDWIDTH=20000000,AVERAGE-BANDWIDTH=8000000,CODECS=\"\(hevc),ec-3\""
if let dolby { masterPlaylist += ",SUPPLEMENTAL-CODECS=\"\(dolby)/db1p\"" }
masterPlaylist += ",VIDEO-RANGE=PQ,RESOLUTION=3840x1920,FRAME-RATE=23.976\nvideo.m3u8\n"
log("codecs: \(hevc)\(dolby.map { " + \($0)" } ?? ""); \(segments.count) segments, \(String(format: "%.1f", totalDuration)) s")

/// What to answer for a path, with its content type.
func resource(for path: String) -> (data: Data, type: String)? {
    switch path {
    case "master.m3u8": return (Data(masterPlaylist.utf8), "application/vnd.apple.mpegurl")
    case "video.m3u8", "index.m3u8": return (Data(mediaPlaylist.utf8), "application/vnd.apple.mpegurl")
    case "init.mp4": return (initData, "video/mp4")
    default:
        guard path.hasSuffix(".m4s"), let data = try? Data(contentsOf: directory.appendingPathComponent(path)) else { return nil }
        return (data, "video/iso.segment")
    }
}
if redirectAll {
    for (name, text) in [("master.m3u8", masterPlaylist), ("video.m3u8", mediaPlaylist), ("index.m3u8", mediaPlaylist)] {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
var requestLog: [String] = []
func record(_ text: String) { DispatchQueue.main.async { requestLog.append(text); log("  ← " + text) } }

// MARK: Transport A: loopback HTTP

final class LoopbackServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "loopback")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }
    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                if case .ready = state, !resumed, let port = self.listener.port?.rawValue { resumed = true; continuation.resume(returning: port) }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }
    func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let lines = request.components(separatedBy: "\r\n")
            let path = lines[0].split(separator: " ").dropFirst().first.map { String($0.dropFirst()) } ?? ""
            let range = lines.first { $0.lowercased().hasPrefix("range:") }?.split(separator: "=").last.map(String.init)
            guard let (body, type) = resource(for: path) else {
                record("HTTP \(path) → 404")
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            var status = "200 OK", payload = body, extra = ""
            if let range, let first = range.split(separator: "-", omittingEmptySubsequences: false).first.flatMap({ Int($0) }) {
                let last = range.split(separator: "-", omittingEmptySubsequences: false).last.flatMap { Int($0) } ?? body.count - 1
                let end = min(last, body.count - 1)
                payload = body.subdata(in: first..<end + 1)
                status = "206 Partial Content"
                extra = "Content-Range: bytes \(first)-\(end)/\(body.count)\r\n"
            }
            record("HTTP \(path)\(range.map { " [bytes=\($0)]" } ?? "") → \(status.prefix(3)) \(payload.count) B")
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

// MARK: Transport B: AVAssetResourceLoader

final class Loader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "resource-loader")
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == "nitpicker-remux" else { return false }
        let path = url.lastPathComponent
        if redirectToFiles, redirectAll || !path.hasSuffix(".m3u8") {
            let fileURL = directory.appendingPathComponent(path)
            loadingRequest.redirect = URLRequest(url: fileURL)
            loadingRequest.response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": fileURL.absoluteString])
            record("loader \(path) → redirect \(fileURL.lastPathComponent)")
            loadingRequest.finishLoading()
            return true
        }
        guard let (body, type) = resource(for: path) else {
            record("loader \(path) → not found")
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return true
        }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = type == "application/vnd.apple.mpegurl" ? "public.m3u-playlist" : (type == "video/mp4" ? "public.mpeg-4" : "public.mpeg-4")
            info.contentLength = Int64(body.count)
            info.isByteRangeAccessSupported = true
        }
        var served = 0
        if let request = loadingRequest.dataRequest {
            let offset = Int(request.requestedOffset)
            let length = request.requestsAllDataToEndOfResource ? body.count - offset : min(request.requestedLength, body.count - offset)
            if offset < body.count, length > 0 { request.respond(with: body.subdata(in: offset..<offset + length)); served = length }
        }
        record("loader \(path) [offset \(loadingRequest.dataRequest?.requestedOffset ?? 0), \(loadingRequest.dataRequest?.requestedLength ?? 0) B] → \(served) B")
        loadingRequest.finishLoading()
        return true
    }
}

// MARK: Playback

@MainActor
func run() async -> Int32 {
    var url: URL
    let loader = Loader()
    var server: LoopbackServer?
    let entry = useMaster ? "master.m3u8" : "index.m3u8"
    let asset: AVURLAsset
    if mode == "http" {
        let s = try! LoopbackServer()
        server = s
        let port = await s.start()
        url = URL(string: "http://127.0.0.1:\(port)/\(entry)")!
        asset = AVURLAsset(url: url)
    } else {
        url = URL(string: "nitpicker-remux://stream/\(entry)")!
        asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }
    log("mode=\(mode) entry=\(entry) url=\(url)")
    _ = server

    let item = AVPlayerItem(asset: asset)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true  // audio still decodes; keep the machine quiet

    var frames = 0
    var firstFrameAt: Double?
    var colorTags = ""
    var seeked = false
    var seekAcknowledged = false
    var maxTime = 0.0
    var reportedTracks = false
    var shown: [Double] = []   // presentation time of every frame pulled, in order
    var shownSinceSeek: [Double] = []
    var seekDoneAt: Date?
    var clock: [(host: Double, media: Double)] = []   // player clock samples after the seek
    let deadline = Date().addingTimeInterval(timeout)
    player.play()

    while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(12))
        if item.status == .failed {
            log("FAILED: \(item.error.map { "\($0)" } ?? "unknown")")
            if let events = item.errorLog()?.events.last { log("  error log: \(events.errorStatusCode) \(events.errorComment ?? "")") }
            return 1
        }
        let time = player.currentTime().seconds
        if time.isFinite { maxTime = max(maxTime, time) }
        if seekDoneAt != nil, time.isFinite { clock.append((Date().timeIntervalSince(startedAt), time)) }
        if item.status == .readyToPlay, !reportedTracks {
            reportedTracks = true
            log("ready: duration \(String(format: "%.2f", item.duration.seconds)) s, presentationSize \(item.presentationSize)")
            for track in item.tracks {
                guard let assetTrack = track.assetTrack, let description = (try? await assetTrack.load(.formatDescriptions))?.first else { continue }
                let subtype = String(decoding: withUnsafeBytes(of: CMFormatDescriptionGetMediaSubType(description).bigEndian) { Array($0) }, as: UTF8.self)
                log("  track \(assetTrack.mediaType.rawValue): \(subtype), enabled=\(track.isEnabled)")
            }
        }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        var display = CMTime.invalid
        if output.hasNewPixelBuffer(forItemTime: itemTime), let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &display) {
            frames += 1
            if display.isValid { shown.append(display.seconds); shownSinceSeek.append(display.seconds) }
            if let done = seekDoneAt, shownSinceSeek.count == 1 {
                log(String(format: "first frame after the seek: pts %.3f s, %.0f ms after the seek returned", display.seconds, Date().timeIntervalSince(done) * 1000))
            }
            if firstFrameAt == nil {
                firstFrameAt = Date().timeIntervalSince(startedAt)
                let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String ?? "?"
                let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String ?? "?"
                colorTags = "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)), pixel format \(CVPixelBufferGetPixelFormatType(buffer)), \(primaries) / \(transfer)"
                log("first frame: \(colorTags)")
            }
        }
        if let seekTarget, !seeked, frames > 20 {
            seeked = true
            log("seeking to \(seekTarget) s")
            seekAcknowledged = await player.seek(to: CMTime(seconds: seekTarget, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            seekDoneAt = Date()
            log("seek finished: \(seekAcknowledged), time now \(String(format: "%.2f", player.currentTime().seconds))")
            frames = 0
            shownSinceSeek = []
        }
        let target = playUntil ?? (seekTarget != nil ? seekTarget! + 1.5 : min(5, totalDuration - 1))
        if maxTime >= target, frames > 10, (seekTarget == nil || seeked) { break }
    }
    func continuity(_ times: [Double]) -> String {
        guard times.count > 2 else { return "too few frames" }
        let gaps = zip(times, times.dropFirst()).map { ($1 - $0) * 1000 }
        let backwards = gaps.filter { $0 <= 0 }.count
        let big = gaps.filter { $0 > 90 }
        return String(format: "%d frames from %.3f to %.3f s; gaps ms: median %.1f, max %.1f; %d out-of-order; %d gaps over 90 ms",
                      times.count, times.first!, times.last!, gaps.sorted()[gaps.count / 2], gaps.max()!, backwards, big.count)
    }
    if clock.count > 5 {
        // Wall-clock vs media-clock: steady playback advances the media clock 1 s per second.
        var longestStall = 0.0, stallAt = 0.0, lastMove = clock[0]
        for sample in clock.dropFirst() {
            if sample.media > lastMove.media + 0.001 { lastMove = sample }
            if sample.host - lastMove.host > longestStall { longestStall = sample.host - lastMove.host; stallAt = lastMove.media }
        }
        let span = (clock.last!.media - clock.first!.media) / (clock.last!.host - clock.first!.host)
        log(String(format: "clock after seek: %.2f s of media in %.2f s of wall time (x%.2f); longest standstill %.0f ms (at media %.2f s)",
                   clock.last!.media - clock.first!.media, clock.last!.host - clock.first!.host, span, longestStall * 1000, stallAt))
    }
    log("frame timeline" + (seekTarget != nil ? " after seek" : "") + ": " + continuity(shownSinceSeek))
    if seekTarget == nil, shown.count > 2 {
        // Where did the frames stop and start? Print any hole over 90 ms.
        for (a, b) in zip(shown, shown.dropFirst()) where (b - a) > 0.09 || b <= a {
            log(String(format: "  hole: %.3f → %.3f s (%.0f ms)", a, b, (b - a) * 1000))
        }
    }
    let reachedTarget = frames > 10
    log(String(format: "result: time reached %.2f s, %d frames pulled after the last seek/start, rate %.1f, status %d", maxTime, frames, player.rate, item.status.rawValue))
    if let events = item.accessLog()?.events {
        let stalls = events.reduce(0) { $0 + $1.numberOfStalls }, dropped = events.reduce(0) { $0 + $1.numberOfDroppedVideoFrames }
        log("access log: \(stalls) stalls, \(dropped) dropped video frames, \(events.count) event(s)")
    }
    log("requests served: \(requestLog.count)")
    return reachedTarget && maxTime > 1 ? 0 : 1
}

let status = await run()
exit(status)
