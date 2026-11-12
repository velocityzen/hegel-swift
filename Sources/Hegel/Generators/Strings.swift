import CHegel

/// The characters a string generator draws from.
///
/// Start from a codec's range, narrow it by code point and Unicode general
/// category, then add and remove individual characters.
public struct Alphabet: Sendable, Equatable {
    public var codec: Codec
    public var codepoints: ClosedRange<UInt32>?
    /// Unicode general categories to draw from, such as `"Lu"` or `"Nd"`.
    /// `nil` means every category.
    public var categories: [String]?
    public var excludedCategories: [String]
    public var includedCharacters: String
    public var excludedCharacters: String

    public enum Codec: String, Sendable, Equatable {
        case unicode = "utf-8"
        case ascii = "ascii"
        case latin1 = "latin-1"
    }

    public init(
        codec: Codec = .unicode,
        codepoints: ClosedRange<UInt32>? = nil,
        categories: [String]? = nil,
        excludedCategories: [String] = [],
        includedCharacters: String = "",
        excludedCharacters: String = ""
    ) {
        self.codec = codec
        self.codepoints = codepoints
        self.categories = categories
        self.excludedCategories = excludedCategories
        self.includedCharacters = includedCharacters
        self.excludedCharacters = excludedCharacters
    }

    /// Any Unicode scalar except surrogates.
    public static let unicode = Alphabet()
    /// ASCII, U+0000 to U+007F.
    public static let ascii = Alphabet(codec: .ascii)
    /// Latin-1, U+0000 to U+00FF.
    public static let latin1 = Alphabet(codec: .latin1)

    /// Exactly the characters in `characters`.
    public static func characters(_ characters: String) -> Alphabet {
        Alphabet(categories: [], includedCharacters: characters)
    }
}

/// A libhegel string generator, built once and shared by every draw.
final class StringGeneratorHandle: @unchecked Sendable {
    let raw: OpaquePointer?
    let failure: String?

    init(_ build: (OpaquePointer, inout OpaquePointer?) -> hegel_result_t) {
        let context = EngineContext()
        var handle: OpaquePointer?
        let code = build(context.raw, &handle)
        if code == HEGEL_OK, let handle {
            raw = handle
            failure = nil
        } else {
            raw = nil
            failure = context.lastError
        }
    }

    deinit {
        hegel_string_generator_free(nil, raw)
    }

    func gen(label: Label) -> Gen<String> {
        Gen(label: label) { tc, printer in
            guard let raw = self.raw else {
                throw HegelError.usage(self.failure ?? "invalid string generator")
            }
            let value = try tc.generateString(raw)
            printer.text(String(reflecting: value))
            return value
        }
    }
}

extension Gen where Value == String {
    /// A string of characters from `alphabet` whose length, in Unicode
    /// scalars, is in `count`. Without a range the length is up to the
    /// engine's default maximum for text.
    public static func string(of alphabet: Alphabet = .unicode, count: ClosedRange<Int>? = nil)
        -> Gen<String>
    {
        let (minCount, maxCount) = sizeBounds(count, defaultMax: maxSizeDefault)
        let handle = StringGeneratorHandle { context, out in
            withOptionalHegelString(alphabet.codec.rawValue) { codec in
                withHegelStrings(alphabet.categories) { categories, categoriesCount in
                    withHegelStrings(alphabet.excludedCategories) { excluded, excludedCount in
                        alphabet.includedCharacters.withHegelString { include in
                            alphabet.excludedCharacters.withHegelString { exclude in
                                hegel_string_generator_text(
                                    context,
                                    minCount,
                                    maxCount,
                                    codec,
                                    alphabet.codepoints?.lowerBound ?? 0,
                                    alphabet.codepoints?.upperBound ?? .max,
                                    categories,
                                    categoriesCount,
                                    excluded,
                                    excludedCount,
                                    include,
                                    exclude,
                                    &out
                                )
                            }
                        }
                    }
                }
            }
        }
        return handle.gen(label: Label.string.combined(with: .named("text")))
    }

    /// A string matching the regular expression `pattern`, in Python `re`
    /// syntax. With `fullMatch` false the match may be padded on either
    /// side.
    public static func matching(_ pattern: String, fullMatch: Bool = true) -> Gen<String> {
        let handle = StringGeneratorHandle { context, out in
            pattern.withHegelString { view in
                hegel_string_generator_regex(context, view, fullMatch, nil, &out)
            }
        }
        return handle.gen(label: Label.string.combined(with: .named("regex")))
    }

    /// An email address, such as `alice@example.com`.
    public static var email: Gen<String> {
        StringGeneratorHandle { hegel_string_generator_email($0, &$1) }
            .gen(label: Label.string.combined(with: .named("email")))
    }

    /// An `http` or `https` URL.
    public static var url: Gen<String> {
        StringGeneratorHandle { hegel_string_generator_url($0, &$1) }
            .gen(label: Label.string.combined(with: .named("url")))
    }

    /// A fully qualified domain name of at most `maxLength` characters.
    public static func domain(maxLength: Int = 255) -> Gen<String> {
        StringGeneratorHandle { hegel_string_generator_domain($0, UInt64(max(maxLength, 0)), &$1) }
            .gen(label: Label.string.combined(with: .named("domain")))
    }
}

extension Gen where Value == Character {
    /// One character from `alphabet`.
    public static func character(of alphabet: Alphabet = .unicode) -> Gen<Character> {
        Gen<String>.string(of: alphabet, count: 1...1)
            .mapSilently { $0.first ?? "\0" }
    }
}

/// Calls `body` with a C array of libhegel string views, or nil for nil.
private func withHegelStrings<R>(
    _ strings: [String]?,
    _ body: (UnsafePointer<hegel_string_t>?, Int) -> R
) -> R {
    guard let strings else {
        return body(nil, 0)
    }
    var bytes: [UInt8] = []
    var ranges: [Range<Int>] = []
    for string in strings {
        let start = bytes.count
        bytes.append(contentsOf: string.utf8)
        ranges.append(start..<bytes.count)
    }
    return bytes.withUnsafeBufferPointer { buffer in
        let base = UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: CChar.self)
        let views = ranges.map { range in
            hegel_string_t(data: base.map { $0 + range.lowerBound }, len: range.count)
        }
        return views.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
    }
}
