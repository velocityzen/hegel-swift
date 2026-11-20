import CHegel

/// A libhegel object a generator builds when it is made, such as a zone
/// spec: its handle, or the engine's reason for rejecting what it was
/// given, which the generator reports as a usage error when it draws.
final class EngineObject: @unchecked Sendable {
    /// The handle, or nil when the engine rejected the object.
    let raw: OpaquePointer?
    /// Why the engine rejected the object.
    let failure: String?
    private let free: (OpaquePointer?) -> Void

    /// Makes the object with `make`, then configures it with `configure`.
    /// When either fails the object is freed and the failure kept.
    init(
        make: (OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> hegel_result_t,
        free: @escaping (OpaquePointer?) -> Void,
        configure: (EngineContext, OpaquePointer) throws(EngineError) -> Void
    ) {
        self.free = free
        let context = EngineContext()
        var handle: OpaquePointer?
        do throws(EngineError) {
            try context.call { make($0, &handle) }
            guard let handle else {
                throw EngineError(code: HEGEL_E_INVALID_ARG, message: "libhegel returned no handle")
            }
            try configure(context, handle)
            raw = handle
            failure = nil
        } catch {
            free(handle)
            raw = nil
            failure = error.message
        }
    }

    deinit {
        free(raw)
    }

    /// The handle, or the usage error that made it invalid.
    func handle() throws -> OpaquePointer {
        guard let raw else {
            throw HegelError.usage(failure ?? "libhegel rejected the generator")
        }
        return raw
    }
}

/// The message of an engine check that failed, or nil when it passed.
func engineCheck(_ check: (OpaquePointer) -> hegel_result_t) -> String? {
    let context = EngineContext()
    do {
        try context.call(check)
        return nil
    } catch {
        return error.message
    }
}

/// The text a `hegel_format_*` call gives a value.
func engineText(_ format: (UnsafeMutablePointer<hegel_owned_string_t>) -> hegel_result_t) -> String
{
    var text = hegel_owned_string_t()
    guard format(&text) == HEGEL_OK else {
        return ""
    }
    defer { hegel_owned_string_free(nil, &text) }
    return String(hegelString: text)
}

/// A string libhegel allocated for the caller, copied out and freed.
func ownedString(_ text: inout hegel_owned_string_t) -> String {
    defer { hegel_owned_string_free(nil, &text) }
    return String(hegelString: text)
}

/// UTF-8 copies of strings that libhegel structs point to, kept until the
/// pool goes away. Keep the pool alive across the call that reads them.
final class StringPool {
    private var buffers: [UnsafeMutableRawBufferPointer] = []

    func view(_ string: String) -> hegel_string_t {
        let bytes = Array(string.utf8)
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: max(bytes.count, 1),
            alignment: 1
        )
        buffer.copyBytes(from: bytes)
        buffers.append(buffer)
        let data = UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: CChar.self)
        return hegel_string_t(data: data, len: bytes.count)
    }

    deinit {
        for buffer in buffers {
            buffer.deallocate()
        }
    }
}
