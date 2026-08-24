#if canImport(Foundation)
    import Foundation
#endif

/// A presentation intent carried by one run of text.
///
/// The vocabulary mirrors the subset of Foundation's
/// `InlinePresentationIntent` that maps onto a distinct inline element, so a
/// later migration to that type is a rename rather than a re-model.
public enum InlineTextIntent: Hashable, Sendable, CaseIterable {
    /// Text with strong importance, conventionally rendered bold.
    case stronglyEmphasized
    /// Text with stress emphasis, conventionally rendered italic.
    case emphasized
    /// A fragment of computer code.
    case code
}

/// Text split into runs, each carrying its own presentation intents.
///
/// A run is a maximal span sharing one intent set; adjacent runs whose intents
/// match are merged on construction, so the same text always produces the same
/// runs regardless of how it was appended.
///
/// This is a native type rather than a typealias for Foundation's
/// `AttributedString`: `AttributedString` requires macOS 12 / iOS 15, while
/// this package deploys to macOS 10.15 / iOS 13. ``init(_:)`` converts from the
/// Foundation type where the platform provides it.
public struct AttributedText: Hashable, Sendable {
    /// A maximal span of text sharing one set of intents.
    public struct Run: Hashable, Sendable {
        /// The run's characters.
        public var text: String
        /// What the run's text means, which decides the element it emits as.
        public var intents: Set<InlineTextIntent>

        /// Creates a run.
        ///
        /// - Parameters:
        ///   - text: The run's characters.
        ///   - intents: What the run's text means.
        public init(_ text: String, intents: Set<InlineTextIntent> = []) {
            self.text = text
            self.intents = intents
        }
    }

    /// The runs, in reading order.
    public private(set) var runs: [Run]

    /// The text of every run concatenated, with all intents dropped.
    ///
    /// This is what a backend with no inline-run support displays, and what a
    /// reader copying the whole group gets.
    public var plainText: String {
        runs.map(\.text).joined()
    }

    /// Creates attributed text from runs, merging any adjacent pair that share
    /// their intents.
    ///
    /// - Parameter runs: The runs, in reading order.
    public init(runs: [Run]) {
        self.runs = []
        for run in runs where !run.text.isEmpty {
            append(run)
        }
    }

    /// Creates attributed text holding one run.
    ///
    /// - Parameters:
    ///   - text: The run's characters.
    ///   - intents: What the text means.
    public init(_ text: String, intents: Set<InlineTextIntent> = []) {
        self.init(runs: [Run(text, intents: intents)])
    }

    /// Adds a run to the end, merging it into the last run if their intents
    /// match.
    ///
    /// - Parameter run: The run to add.
    public mutating func append(_ run: Run) {
        guard !run.text.isEmpty else {
            return
        }
        if let last = runs.last, last.intents == run.intents {
            runs[runs.count - 1].text += run.text
            return
        }
        runs.append(run)
    }
}

#if canImport(Foundation)
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    extension AttributedText {
        /// Converts Foundation's attributed string, keeping the intents this
        /// type models and dropping the rest.
        ///
        /// - Parameter attributedString: The string to convert.
        public init(_ attributedString: AttributedString) {
            var runs: [Run] = []
            for run in attributedString.runs {
                let text = String(attributedString[run.range].characters)
                runs.append(Run(text, intents: Self.intents(of: run.inlinePresentationIntent)))
            }
            self.init(runs: runs)
        }

        /// Maps Foundation's intent option set onto the cases this type models.
        ///
        /// - Parameter intent: The Foundation intent, if the run carried one.
        /// - Returns: The intents this type represents.
        private static func intents(
            of intent: InlinePresentationIntent?
        ) -> Set<InlineTextIntent> {
            guard let intent else {
                return []
            }
            var intents: Set<InlineTextIntent> = []
            if intent.contains(.stronglyEmphasized) {
                intents.insert(.stronglyEmphasized)
            }
            if intent.contains(.emphasized) {
                intents.insert(.emphasized)
            }
            if intent.contains(.code) {
                intents.insert(.code)
            }
            return intents
        }
    }
#endif
