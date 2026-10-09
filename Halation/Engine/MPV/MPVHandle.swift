import FFmpegKit
import Foundation

/// What the mpv thread tells the engine. Property values are read afresh by the engine when it hears a name; mpv's getters
/// are thread-safe.
enum MPVEvent: Sendable {
    case propertyChanged(String)
    case fileLoaded
    case playbackRestart
    /// `reason` is mpv's `mpv_end_file_reason`; `error` is a message when the file ended because of one.
    case endFile(reason: Int32, error: String?)
    case log(level: String, prefix: String, text: String)
    case shutdown
}

/// A thin Swift face on one `mpv_handle`: options, properties, commands and the event loop. It owns the handle; `destroy`
/// ends it. Everything here may be called from any thread.
final class MPVHandle: @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Events from mpv's own thread, in order. Finishes at shutdown.
    let events: AsyncStream<MPVEvent>
    private let continuation: AsyncStream<MPVEvent>.Continuation
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private var thread: Thread?
    private var isDestroying = false
    /// Signalled when the event thread has returned; mpv can't be destroyed while another thread waits on it.
    private let eventThreadDone = DispatchSemaphore(value: 0)

    /// Creates and initialises an mpv instance. `options` are set before initialisation (some can't change afterwards,
    /// `target-colorspace-hint` among them). `layer` is the `CAMetalLayer` mpv draws into.
    init(layer: AnyObject, options: [(String, String)], logLevel: String = "warn") throws {
        (events, continuation) = AsyncStream.makeStream(of: MPVEvent.self)
        guard let created = mpv_create() else { throw Failure(message: "The compatibility player couldn't start.") }
        handle = created
        var layerAddress = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        var code = mpv_set_option(created, "wid", MPV_FORMAT_INT64, &layerAddress)
        for (name, value) in options where code >= 0 {
            code = mpv_set_option_string(created, name, value)
            if code < 0 { code = 0 }  // an option this build doesn't know isn't fatal
        }
        _ = mpv_request_log_messages(created, logLevel)
        code = mpv_initialize(created)
        guard code >= 0 else {
            mpv_terminate_destroy(created)
            handle = nil
            throw Failure(message: "The compatibility player couldn't start (\(Self.message(code))).")
        }
        let loop = Thread { [weak self] in self?.runEvents() }
        loop.name = "halation.mpv-events"
        loop.qualityOfService = .userInitiated
        thread = loop
        loop.start()
    }

    deinit { destroy() }

    // MARK: Lifetime

    /// Stops playback and frees the instance. Safe to call twice. It waits for mpv's threads, so the engine calls it off the
    /// main actor.
    func destroy() {
        lock.lock()
        guard !isDestroying, let current = handle else { lock.unlock(); return }
        isDestroying = true
        lock.unlock()
        // `quit` ends the core and the event thread with it; only then is it safe to free the handle.
        _ = command(["quit"])
        _ = eventThreadDone.wait(timeout: .now() + 3)
        lock.lock()
        handle = nil
        lock.unlock()
        mpv_terminate_destroy(current)
        continuation.finish()
    }

    private func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        return body(handle)
    }

    // MARK: Events

    private func runEvents() {
        defer { eventThreadDone.signal() }
        while true {
            // Read the handle without holding the lock across the wait, which `destroy` would deadlock on.
            guard let current = withHandle({ $0 }) else { return }
            guard let event = mpv_wait_event(current, 0.25) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_NONE: continue
            case MPV_EVENT_SHUTDOWN:
                continuation.yield(.shutdown)
                return
            case MPV_EVENT_FILE_LOADED: continuation.yield(.fileLoaded)
            case MPV_EVENT_PLAYBACK_RESTART: continuation.yield(.playbackRestart)
            case MPV_EVENT_END_FILE:
                let info = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                let message = info.error < 0 ? Self.message(info.error) : nil
                continuation.yield(.endFile(reason: Int32(info.reason.rawValue), error: message))
            case MPV_EVENT_PROPERTY_CHANGE:
                let property = event.pointee.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                continuation.yield(.propertyChanged(String(cString: property.name)))
            case MPV_EVENT_LOG_MESSAGE:
                let log = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                continuation.yield(.log(level: String(cString: log.level), prefix: String(cString: log.prefix), text: String(cString: log.text)))
            default: continue
            }
        }
    }

    // MARK: Properties

    /// Asks mpv to report changes of `name` as `.propertyChanged`.
    func observe(_ name: String) {
        _ = withHandle { mpv_observe_property($0, 0, name, MPV_FORMAT_NONE) }
    }

    func string(_ name: String) -> String? {
        withHandle { handle in
            guard let value = mpv_get_property_string(handle, name) else { return nil }
            defer { mpv_free(value) }
            return String(cString: value)
        } ?? nil
    }

    func double(_ name: String) -> Double? {
        withHandle { handle in
            var value = 0.0
            return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
        } ?? nil
    }

    func int(_ name: String) -> Int? {
        withHandle { handle in
            var value: Int64 = 0
            return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? Int(value) : nil
        } ?? nil
    }

    func flag(_ name: String) -> Bool? {
        withHandle { handle in
            var value: Int32 = 0
            return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
        } ?? nil
    }

    func set(_ name: String, flag value: Bool) {
        _ = withHandle { handle in
            var flag: Int32 = value ? 1 : 0
            return mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
        }
    }

    func set(_ name: String, double value: Double) {
        _ = withHandle { handle in
            var number = value
            return mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &number)
        }
    }

    func set(_ name: String, string value: String) {
        _ = withHandle { mpv_set_property_string($0, name, value) }
    }

    // MARK: Commands

    /// Runs a command and waits for it. Returns mpv's error message, or nil on success.
    @discardableResult
    func command(_ parts: [String]) -> String? {
        let code: Int32? = withHandle { handle in
            var arguments: [UnsafePointer<CChar>?] = parts.map { UnsafePointer(strdup($0)) } + [nil]
            defer { for pointer in arguments { if let pointer { free(UnsafeMutablePointer(mutating: pointer)) } } }
            return mpv_command(handle, &arguments)
        }
        guard let code, code < 0 else { return nil }
        return Self.message(code)
    }

    static func message(_ code: Int32) -> String {
        String(cString: mpv_error_string(code))
    }
}
