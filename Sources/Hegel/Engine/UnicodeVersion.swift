import CHegel

/// Makes the engine's string generators follow the Unicode tables of the
/// Swift standard library this process runs with, so that what they draw
/// agrees with `Character` and `Unicode.Scalar.Properties`: a character the
/// standard library doesn't know yet is in no category, and one it
/// classifies differently is in the category it says.
///
/// The engine reads the version when a text, regex or grammar generator is
/// built, so evaluate this first. It runs once per process.
let unicodeVersionSet: Void = {
    let context = hegel_context_new()
    defer { hegel_context_free(context) }
    // An error leaves the engine on its own tables: a version older than
    // the oldest it has is the only way to get one, and those tables are
    // the nearest it can do.
    _ = hostUnicodeVersion.withHegelString { view in
        hegel_set_unicode_version(context, view)
    }
}()

/// The Unicode version of the standard library's tables, as the engine
/// takes it: `"major.minor.0"`.
///
/// Swift has no API for it, but every assigned scalar knows the version
/// that introduced it, so the newest of those is the tables' version. (The
/// update versions, like the `1` of 15.1, are found the same way; patch
/// releases don't add characters.)
let hostUnicodeVersion: String = {
    var newest: (major: Int, minor: Int) = (0, 0)
    for value in UInt32(0)...0x10FFFF {
        if let scalar = Unicode.Scalar(value),
            let age = scalar.properties.age,
            age > newest
        {
            newest = age
        }
    }
    return "\(newest.major).\(newest.minor).0"
}()
