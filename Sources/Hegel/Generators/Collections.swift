extension Gen {
    /// An array of elements from `element`, with a count in `count`.
    /// Shrinks toward fewer, smaller elements.
    public static func array<Element>(of element: Gen<Element>, count: ClosedRange<Int>? = nil)
        -> Gen<Value> where Value == [Element]
    {
        let (minCount, maxCount) = sizeBounds(count, defaultMax: .max)
        return Gen(label: Label.array.combined(with: element.label)) { tc, printer in
            let collection = try tc.newCollection(minCount: minCount, maxCount: maxCount)
            var elements: [Element] = []
            try printer.collectionGroup(open: "[", close: "]") { printElement in
                while try collection.more() {
                    try printElement {
                        elements.append(try tc.draw(element, printer: printer))
                    }
                }
            }
            return elements
        }
    }

    /// A set of distinct elements from `element`, with a count in `count`.
    public static func set<Element: Hashable & SendableMetatype>(
        of element: Gen<Element>,
        count: ClosedRange<Int>? = nil
    )
        -> Gen<Value> where Value == Set<Element>
    {
        let (minCount, maxCount) = sizeBounds(count, defaultMax: .max)
        return Gen(label: Label.set.combined(with: element.label)) { tc, printer in
            let collection = try tc.newCollection(minCount: minCount, maxCount: maxCount)
            var elements: Set<Element> = []
            try printer.collectionGroup(open: "Set([", close: "])") { printElement in
                while try collection.more() {
                    do {
                        try printElement {
                            let value = try tc.draw(element, printer: printer)
                            guard elements.insert(value).inserted else {
                                throw Duplicate()
                            }
                        }
                    } catch is Duplicate {
                        try collection.reject()
                    }
                }
            }
            return elements
        }
    }

    /// A dictionary with distinct keys from `keys` and values from `values`,
    /// with a count in `count`.
    public static func dictionary<Key: Hashable & SendableMetatype, Element>(
        keys: Gen<Key>,
        values: Gen<Element>,
        count: ClosedRange<Int>? = nil
    ) -> Gen<Value> where Value == [Key: Element] {
        let (minCount, maxCount) = sizeBounds(count, defaultMax: .max)
        let label = Label.dictionary.combined(with: keys.label, values.label)
        return Gen(label: label) { tc, printer in
            let collection = try tc.newCollection(minCount: minCount, maxCount: maxCount)
            var dictionary: [Key: Element] = [:]
            try printer.collectionGroup(open: "[", close: "]", empty: ":") { printElement in
                while try collection.more() {
                    do {
                        try printElement {
                            let key = try tc.draw(keys, printer: printer)
                            guard dictionary[key] == nil else {
                                throw Duplicate()
                            }
                            printer.text(": ")
                            dictionary[key] = try tc.draw(values, printer: printer)
                        }
                    } catch is Duplicate {
                        try collection.reject()
                    }
                }
            }
            return dictionary
        }
    }
}

private struct Duplicate: Error {}

extension Printer {
    /// Prints a bracketed collection. `body` prints each element through
    /// the function it is given, which adds the separator and discards the
    /// element's output when printing it throws.
    fileprivate func collectionGroup(
        open: String,
        close: String,
        empty: String = "",
        _ body: (_ printElement: (() throws -> Void) throws -> Void) throws -> Void
    ) throws {
        var count = 0
        try group(indent: 4, open: open, close: close) {
            breakable("")
            try body { printElement in
                try speculate {
                    if count > 0 {
                        text(",")
                        breakable(" ")
                    }
                    try printElement()
                }
                count += 1
            }
            if count == 0 {
                text(empty)
            } else {
                ifBreak(",")
            }
            breakable("")
        }
    }
}
