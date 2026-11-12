/// A run that ended without a verdict on the property.
public enum HegelError: Error, Equatable, CustomStringConvertible {
    /// A health check failed.
    case healthCheck(HealthCheck, message: String)
    /// The test gave different outcomes when replayed on the same data.
    case flaky(String)
    /// Data generation diverged when the same choices were replayed.
    case nondeterministic(String)
    /// No valid test case could be generated: every one was rejected.
    case unsatisfiable(String)
    /// The library was used incorrectly, for example with invalid settings
    /// or generator bounds.
    case usage(String)
    /// A bug in Hegel.
    case engine(String)
    /// The linked libhegel is not the version this package was built for.
    case versionMismatch(expected: String, actual: String)
    /// A reproduce blob replayed without failing.
    case notReproduced(blob: String)

    public var description: String {
        switch self {
            case .healthCheck(let check, let message):
                "FailedHealthCheck: \(check): \(message)"
            case .flaky(let message):
                "Flaky: \(message)"
            case .nondeterministic(let message):
                "Nondeterministic: \(message)"
            case .unsatisfiable(let message):
                "Unsatisfiable: \(message)"
            case .usage(let message):
                "Usage error: \(message)"
            case .engine(let message):
                "Hegel engine error: \(message)"
            case .versionMismatch(let expected, let actual):
                "hegel-swift was built for libhegel \(expected), but \(actual) is linked"
            case .notReproduced:
                """
                The reproduce blob did not reproduce a failure. The failure may \
                have been fixed, or, for a nondeterministic failure, it may not \
                have recurred within the replay budget.
                """
        }
    }
}

/// Lets an error say which bug it is.
///
/// Hegel groups failures by origin: failures with the same origin are one
/// bug and are shrunk together, and each new origin is a new bug. By default
/// an error's origin is its type. Conform to give errors of one type
/// distinct origins, such as the location of a failed check.
public protocol FailureOrigin {
    var failureOrigin: String { get }
}

func origin(of error: any Error) -> String {
    if let error = error as? any FailureOrigin {
        return error.failureOrigin
    }
    return "Error: \(String(reflecting: type(of: error)))"
}

/// A property that failed: every distinct counterexample the run found,
/// each shrunk to a minimal one.
public struct PropertyFailure: Error, CustomStringConvertible {
    public var counterexamples: [Counterexample]

    public init(counterexamples: [Counterexample]) {
        self.counterexamples = counterexamples
    }

    /// One distinct failure.
    public struct Counterexample: Sendable {
        /// The origin the engine grouped this failure under.
        public var origin: String
        /// The error the test raised on the minimal example.
        public var error: any Error
        /// The values drawn for the minimal example, one `let` per line.
        public var drawn: [String]
        /// How reliably a nondeterministic failure reproduced, if it was
        /// nondeterministic.
        public var caveat: String?
        /// A blob that replays this example, if the engine produced one.
        public var reproductionBlob: String?
        /// Whether the report includes the reproduce blob, as the
        /// `printBlob` setting asks.
        public var printsReproduction: Bool
        /// The explicit example that failed, or nil for a generated one.
        public var example: Example?

        public init(
            origin: String,
            error: any Error,
            drawn: [String],
            caveat: String? = nil,
            reproductionBlob: String? = nil,
            printsReproduction: Bool = true,
            example: Example? = nil
        ) {
            self.origin = origin
            self.error = error
            self.drawn = drawn
            self.caveat = caveat
            self.reproductionBlob = reproductionBlob
            self.printsReproduction = printsReproduction
            self.example = example
        }

        /// The report for this failure. `reproduce` turns the blob into the
        /// line that tells the reader how to replay it.
        public func report(reproduce: (String) -> String = Self.defaultReproduceHint) -> String {
            var lines = drawn
            lines.append(String(describing: error))
            lines.append(contentsOf: notes(reproduce: reproduce))
            return lines.joined(separator: "\n")
        }

        /// The lines a report adds after the error: the caveat, and how to
        /// reproduce the failure.
        public func notes(reproduce: (String) -> String = Self.defaultReproduceHint) -> [String] {
            var lines: [String] = []
            if let caveat {
                lines.append("note: \(caveat)")
            }
            if printsReproduction, let reproductionBlob {
                lines.append("")
                lines.append(reproduce(reproductionBlob))
            }
            return lines
        }

        public static func defaultReproduceHint(_ blob: String) -> String {
            """
            To reproduce this failure, pass the blob to the run:
                reproducing: "\(blob)"
            """
        }
    }

    /// The report for every failure, under a count header when there are
    /// several.
    public func report(
        reproduce: (String) -> String = Counterexample.defaultReproduceHint
    ) -> String {
        if counterexamples.count == 1 {
            return "Property-based test failed:\n\n"
                + counterexamples[0].report(reproduce: reproduce)
        }
        var text = "Property-based test failed with \(counterexamples.count) distinct failures."
        for counterexample in counterexamples {
            text += "\n\n" + counterexample.report(reproduce: reproduce)
        }
        return text
    }

    public var description: String {
        report()
    }
}
