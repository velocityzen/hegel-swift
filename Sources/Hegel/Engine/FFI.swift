import CHegel

/// A libhegel error context: holds the message of the last failed call.
///
/// A context must not be used from two threads at once, so every handle that
/// calls into libhegel owns its own.
final class EngineContext {
    let raw: OpaquePointer

    init() {
        raw = hegel_context_new()
    }

    deinit {
        hegel_context_free(raw)
    }

    var lastError: String {
        String(hegelString: hegel_context_last_error(raw))
    }

    /// Calls `body` with this context and turns a failing result code into
    /// a thrown error.
    @discardableResult
    func call(_ body: (OpaquePointer) -> hegel_result_t) throws(EngineError) -> hegel_result_t {
        let code = body(raw)
        if code == HEGEL_OK {
            return code
        }
        throw EngineError(code: code, message: lastError)
    }
}

/// A libhegel call that did not return `HEGEL_OK`.
struct EngineError: Error {
    let code: hegel_result_t
    let message: String

    var isStopTest: Bool { code == HEGEL_E_STOP_TEST }
    var isAssume: Bool { code == HEGEL_E_ASSUME }
}

extension String {
    /// Copies a libhegel string view, which may contain interior NULs.
    init(hegelString view: hegel_string_t) {
        guard let data = view.data, view.len > 0 else {
            self = ""
            return
        }
        let bytes = UnsafeRawBufferPointer(start: data, count: view.len)
        self = String(decoding: bytes, as: UTF8.self)
    }

    /// Calls `body` with a libhegel string view of this string, valid for the
    /// duration of the call.
    @discardableResult
    func withHegelString<R, E: Error>(
        _ body: (hegel_string_t) throws(E) -> R
    ) throws(E) -> R {
        var copy = self
        // Swift 6.3's `withUTF8` is `rethrows`, not typed-throws, so the
        // error goes through a `Result` to keep its type.
        let result = copy.withUTF8 { (buffer) -> Result<R, E> in
            let data = UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: CChar.self)
            return Result { () throws(E) -> R in
                try body(hegel_string_t(data: data, len: buffer.count))
            }
        }
        return try result.get()
    }
}

/// Calls `body` with a pointer to a libhegel string view of `string`, or nil
/// when `string` is nil (libhegel's spelling of an absent optional string).
@discardableResult
func withOptionalHegelString<R, E: Error>(
    _ string: String?,
    _ body: (UnsafePointer<hegel_string_t>?) throws(E) -> R
) throws(E) -> R {
    guard let string else {
        return try body(nil)
    }
    return try string.withHegelString { (view) throws(E) -> R in
        var view = view
        return try body(&view)
    }
}

/// The version of the libhegel engine linked into this process.
public var engineVersion: String {
    var version = hegel_string_t()
    hegel_version(nil, &version)
    return String(hegelString: version)
}
