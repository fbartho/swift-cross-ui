import SwiftCrossUI

/// One ``SwiftCrossUI/Text`` child of a ``TextGroup``, with the styling the
/// author attached to it.
///
/// The styling is captured as data rather than as view modifiers so the group
/// can both emit each run as its own inline element and, on a backend with no
/// inline-run support, flatten every run into a single string.
public struct TextRun: Hashable, Sendable {
    /// The run's characters.
    public var text: String
    /// Whether the run asked for its style's emphasized weight.
    public var isEmphasized: Bool
    /// Whether the run asked to be italicized.
    public var isItalic: Bool
    /// A text style the run declared for itself, overriding the group's.
    public var font: Font?
    /// A color the run declared for itself, overriding the group's.
    public var color: Color?

    /// Creates a run from a text view.
    ///
    /// - Parameter text: The text view the author wrote.
    public init(_ text: Text) {
        self.init(text.string)
    }

    /// Creates a run from a string.
    ///
    /// - Parameter text: The run's characters.
    public init(_ text: String) {
        self.text = text
        isEmphasized = false
        isItalic = false
        font = nil
        color = nil
    }

    /// The run's intents, as the runs model spells them.
    public var intents: Set<InlineTextIntent> {
        var intents: Set<InlineTextIntent> = []
        if isEmphasized {
            intents.insert(.stronglyEmphasized)
        }
        if isItalic {
            intents.insert(.emphasized)
        }
        return intents
    }

    /// Uses the run's style's emphasized weight, as
    /// ``SwiftCrossUI/View/emphasized()`` does for a view.
    ///
    /// - Returns: The run, emphasized.
    public func emphasized() -> TextRun {
        var run = self
        run.isEmphasized = true
        return run
    }

    /// Italicizes the run, as ``SwiftCrossUI/View/italic()`` does for a view.
    ///
    /// - Returns: The run, italicized.
    public func italic() -> TextRun {
        var run = self
        run.isItalic = true
        return run
    }

    /// Overrides the text style the run inherits from its group.
    ///
    /// - Parameter font: The style to use for this run.
    /// - Returns: The run, restyled.
    public func font(_ font: Font) -> TextRun {
        var run = self
        run.font = font
        return run
    }

    /// Overrides the color the run inherits from its group.
    ///
    /// - Parameter color: The color to use for this run.
    /// - Returns: The run, recolored.
    public func foregroundColor(_ color: Color) -> TextRun {
        var run = self
        run.color = color
        return run
    }
}

/// Builds the runs of a ``TextGroup``.
///
/// Only ``SwiftCrossUI/Text`` and ``TextRun`` are buildable: a group is one
/// text flow, and a child that isn't text has no run to become.
@resultBuilder
public enum TextRunBuilder {
    public static func buildExpression(_ text: Text) -> [TextRun] {
        [TextRun(text)]
    }

    public static func buildExpression(_ run: TextRun) -> [TextRun] {
        [run]
    }

    public static func buildBlock(_ runs: [TextRun]...) -> [TextRun] {
        runs.flatMap { $0 }
    }

    public static func buildOptional(_ runs: [TextRun]?) -> [TextRun] {
        runs ?? []
    }

    public static func buildEither(first runs: [TextRun]) -> [TextRun] {
        runs
    }

    public static func buildEither(second runs: [TextRun]) -> [TextRun] {
        runs
    }

    public static func buildArray(_ runs: [[TextRun]]) -> [TextRun] {
        runs.flatMap { $0 }
    }
}

/// A request to emit a view's text as inline runs.
///
/// Resolved by identity, and a reference type for that reason: the request is
/// in scope for exactly one text leaf of the group's own making, so the leaf
/// reporting it *is* the group the author wrote.
public final class InlineTextRunRequest: Sendable {
    /// The runs, in reading order.
    public let runs: [TextRun]

    /// Creates a request.
    ///
    /// - Parameter runs: The runs to emit.
    public init(runs: [TextRun]) {
        self.runs = runs
    }
}

extension EnvironmentValues {
    /// Inline runs to emit in place of a text view's own string, from
    /// ``TextGroup``.
    ///
    /// Only consumed by StaticHTMLBackend; other backends never read it, which
    /// is what makes a ``TextGroup`` render as its flattened text under them.
    @Entry public var inlineTextRunRequest: InlineTextRunRequest?
}

/// Text whose parts carry different emphasis, rendered as one flow.
///
/// A group holds ``SwiftCrossUI/Text`` children that each state their own
/// emphasis, and renders them as a single run of text — the shape a reader
/// selecting and copying the group gets one uninterrupted string from, and the
/// shape that wraps as one paragraph rather than as a row of independent boxes.
///
/// ```swift
/// TextGroup {
///     Text("This is ")
///     Text("Bold").emphasized()
///     Text("!")
/// }
/// .font(.title)
/// .htmlTag(.h2)
/// ```
///
/// The group carries the styling modifiers ``SwiftCrossUI/Text`` does, and
/// those settings cascade to every run that doesn't override them, so the type
/// scale's responsive size and the document's heading structure stay live for
/// the group as a whole.
///
/// ## Element selection
///
/// Under StaticHTMLBackend the group emits one element, decided in this order:
/// an explicit ``SwiftCrossUI/View/htmlTag(_:)`` wins; otherwise a bare text
/// style on the *group* derives a heading element, exactly as it would for a
/// single ``SwiftCrossUI/Text``; otherwise the group emits a `<span>`. Runs
/// never derive elements of their own, so a heading group is one heading rather
/// than a heading per run.
///
/// A group that should be a paragraph states `.htmlTag(.p)`, the same way a
/// single-``SwiftCrossUI/Text`` paragraph already does. `<span>` is the default
/// because `<p>` cannot nest inside `<p>`: a block default would make a nested
/// group invalid markup.
///
/// ## Other backends
///
/// Backends without inline-run support render the group as its runs' text
/// concatenated, in the group's own style — correct text, with the per-run
/// emphasis dropped.
public struct TextGroup: View {
    /// The runs, in reading order.
    public var runs: [TextRun]

    public var body: some View {
        Text(attributedText.plainText)
            .environment(\.inlineTextRunRequest, InlineTextRunRequest(runs: runs))
    }

    /// The group's content as runs with intents.
    public var attributedText: AttributedText {
        AttributedText(
            runs: runs.map { AttributedText.Run($0.text, intents: $0.intents) }
        )
    }

    /// Creates a group of text runs.
    ///
    /// - Parameter content: The runs making up the group.
    public init(@TextRunBuilder _ content: () -> [TextRun]) {
        runs = content()
    }

    /// Creates a group from attributed text.
    ///
    /// - Parameter attributedText: The runs to render.
    public init(_ attributedText: AttributedText) {
        runs = attributedText.runs.map { run in
            var textRun = TextRun(run.text)
            textRun.isEmphasized = run.intents.contains(.stronglyEmphasized)
            textRun.isItalic = run.intents.contains(.emphasized)
            return textRun
        }
    }
}
