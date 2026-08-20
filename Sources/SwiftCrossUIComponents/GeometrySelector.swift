import Foundation
import SwiftCrossUI

/// The attribute name each branch wrapper carries, keyed to the CSS gating
/// rule that shows/hides it.
private let branchMarkerAttribute = "data-gsel"

/// A structural-variant container: renders a different branch depending on
/// the width of the viewport, or of a named ancestor container.
///
/// Where `.responsive` styling deltas rearrange the *same* children (a
/// restyle), `GeometrySelector` swaps in genuinely different structure or
/// content:
///
/// ```swift
/// GeometrySelector {
///     GeometryCase(..<600) { VStack(alignment: .leading, spacing: 8) { navLinks } }
///     GeometryCase(600...) { HStack(spacing: 16) { navLinks } }
/// }
/// ```
///
/// ## Mechanism
///
/// All branches exist as siblings in one widget tree — a single layout pass
/// lays out every one of them. On the static tier, every branch is emitted,
/// each wrapped in a `div` carrying a `data-gsel` marker; a registered
/// `.style` fragment gates their visibility with `@media`/`@container` rules,
/// so exactly one is visible at any given width. On a measuring tier (native,
/// wasm), a `GeometryReader` picks and instantiates exactly one branch —
/// there is no DOM to hide siblings in, and no reason to build ones that will
/// never render.
///
/// This asymmetry — all branches in the static DOM, one branch on a
/// measuring tier — is an accepted, documented cost, not an oversight:
/// payload and SEO weight scale with total branch size on the static tier,
/// which is fine for a component-sized selector and worth caution for a
/// whole-page one.
///
/// ## Validation
///
/// Branch ranges are checked at construction:
/// - **Overlapping ranges are always rejected.** Two branches that could
///   both match the same width make "which one renders" ambiguous, on every
///   tier.
/// - **Gaps are rejected unless a `GeometryDefault` branch is present.**
///   A width with no matching branch and no fallback would render nothing —
///   almost certainly not what was intended — so it's caught at construction
///   rather than discovered as a blank page at some width nobody tested.
///
/// Both are programmer errors (the declared ranges are static, checkable
/// data, not user input), so violations `precondition`-crash with a message
/// naming the conflicting branches, matching this codebase's established
/// stance for this class of error (see `HTMLFragmentRegistry.register`).
public struct GeometrySelector: View {
    @Environment(\.self) var environment

    /// An identity, threaded into both the registered gating CSS and the
    /// `data-gsel` markers the branches are emitted with, so the two agree
    /// on which selector they're describing even when several
    /// `GeometrySelector`s exist on one page.
    ///
    /// Deterministic — a hash of the branch structure, not a random UUID.
    /// `StaticHTMLRenderer.render` lays the tree out twice (once per color
    /// scheme, see its doc comment), and `GeometrySelector` is a value type
    /// SwiftCrossUI reconstructs on each pass — a random ID would come out
    /// different on the second `init`, so the CSS a first pass registered
    /// (keyed on its own random ID) would never match the `data-gsel`
    /// markers a later pass's `commit()` actually wrote onto the widget
    /// tree. Hashing the declared ranges (stable, known at construction)
    /// makes every reconstruction of the same selector converge on the same
    /// ID, the same way `HTMLDocumentItemContent`'s content-hash dedup keys already
    /// need process-stable hashing (see its `hash(of:)`, which this reuses
    /// the same FNV-1a shape as, for the same reason).
    let selectorID: String
    let branches: [GSelBranch]
    let containerName: String?

    /// Creates a viewport-width selector.
    ///
    /// - Parameter branches: The selector's branches, built from `GeometryCase`
    ///   and at most one trailing `GeometryDefault`.
    public init(@GeometrySelectorBuilder branches: () -> [GSelBranch]) {
        self.init(of: nil, branches: branches)
    }

    /// Creates a container-width selector, scoped to a named ancestor
    /// container.
    ///
    /// - Parameters:
    ///   - container: The name of the ancestor `.container(_:)` this
    ///     selector's branches query. Must match a `.container(_:)` name in
    ///     scope; naming is required (see `.container(_:)`), so there is no
    ///     unnamed form.
    ///   - branches: The selector's branches, built from `GeometryCase` and at
    ///     most one trailing `GeometryDefault`.
    public init(
        of container: String,
        @GeometrySelectorBuilder branches: () -> [GSelBranch]
    ) {
        self.init(of: Optional(container), branches: branches)
    }

    private init(of container: String?, @GeometrySelectorBuilder branches: () -> [GSelBranch]) {
        let built = branches()
        Self.validate(built)
        self.branches = built
        self.containerName = container
        self.selectorID = Self.deterministicSelectorID(for: built, container: container)
    }

    /// A stable identity derived from the branch structure — see the
    /// `selectorID` doc comment for why this can't be random.
    ///
    /// Two structurally-identical `GeometrySelector`s (same ranges, same
    /// container scope) at different call sites converging on the same ID is
    /// an accepted consequence, not a bug: they'd emit byte-identical gating
    /// CSS anyway, so collapsing them via the registry's existing
    /// first-wins dedup is the same "identical content, one rule" behavior
    /// `HTMLDocumentItemContent`'s content-hash keys already rely on — not
    /// different in kind from two components emitting the same stylesheet
    /// link twice.
    private static func deterministicSelectorID(
        for branches: [GSelBranch],
        container: String?
    ) -> String {
        let shape = ([container ?? ""] + branches.map { branch in
            "\(branch.id):\(branch.range.map(\.description) ?? "fallback")"
        }).joined(separator: "|")
        return "gsel-\(HTMLDocumentItemContent.hash(of: shape))"
    }

    /// Rejects an empty branch list, overlapping ranges, and gaps unless a
    /// fallback covers them.
    ///
    /// Delegates to `validationErrors(for:)`, a pure function with no
    /// `precondition` of its own, so the actual overlap/gap reasoning is
    /// unit-testable without needing to observe a crash.
    private static func validate(_ branches: [GSelBranch]) {
        let errors = validationErrors(for: branches)
        precondition(
            errors.isEmpty,
            "GeometrySelector:\n" + errors.map { "- \($0)" }.joined(separator: "\n")
        )
    }

    /// Every construction-time problem with a branch list: an empty list,
    /// overlapping ranges, and gaps not covered by a fallback. Empty when
    /// `branches` is valid.
    static func validationErrors(for branches: [GSelBranch]) -> [String] {
        guard !branches.isEmpty else {
            return ["at least one GeometryCase (or a GeometryDefault) is required."]
        }

        let ranged = branches.compactMap { branch in branch.range.map { (branch.id, $0) } }
        let hasFallback = branches.contains { $0.range == nil }

        guard !ranged.isEmpty || hasFallback else {
            return ["at least one GeometryCase (or a GeometryDefault) is required."]
        }

        var errors: [String] = []

        for i in ranged.indices {
            for j in ranged.indices where j > i {
                let (idA, rangeA) = ranged[i]
                let (idB, rangeB) = ranged[j]
                if rangeA.overlaps(rangeB) {
                    errors.append(
                        """
                        branch \(idA) (\(rangeA)) and branch \(idB) (\(rangeB)) overlap. \
                        Overlapping GeometryCase ranges make it ambiguous which branch should \
                        render at a width both cover — narrow one of the ranges so they no \
                        longer overlap.
                        """
                    )
                }
            }
        }

        guard !hasFallback else {
            return errors
        }

        let sorted = ranged.map(\.1)
            .sorted { ($0.lowerBound ?? -.infinity) < ($1.lowerBound ?? -.infinity) }

        if sorted.first?.lowerBound != nil {
            errors.append(
                """
                no branch covers widths below \(sorted[0].lowerBound!), and no \
                GeometryDefault branch is present. Add a GeometryCase covering that range, or \
                a trailing GeometryDefault.
                """
            )
        }
        if sorted.last?.upperBound != nil {
            errors.append(
                """
                no branch covers widths at or above \(sorted[sorted.count - 1].upperBound!), \
                and no GeometryDefault branch is present. Add a GeometryCase covering that \
                range, or a trailing GeometryDefault.
                """
            )
        }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            let previousEnd = previous.upperBound ?? .infinity
            let nextStart = next.lowerBound ?? -.infinity
            if previousEnd < nextStart {
                errors.append(
                    """
                    no branch covers widths between \(previousEnd) and \(nextStart), and no \
                    GeometryDefault branch is present. Add a GeometryCase covering the gap, or \
                    a trailing GeometryDefault.
                    """
                )
            }
        }

        return errors
    }

    public var body: some View {
        // The registry's presence is StaticHTMLBackend's own signal for "a
        // static-tier render is in progress" (it's seeded only by
        // StaticHTMLRenderer.layOut, and stays nil under every other
        // backend — see HTMLFragmentRegistry's environment entry). Reusing
        // it here, rather than inventing a second is-static-tier flag, keeps
        // there being exactly one place that decides what tier is rendering.
        if environment.htmlFragmentRegistry != nil {
            staticBody
        } else {
            measuringBody
        }
    }

    /// The static tier's arm: every branch, as siblings, each gated by a
    /// registered CSS rule.
    ///
    /// The `data-gsel` marker is applied directly to `branch.content` —
    /// safe even when that content already carries its own author
    /// `.htmlAttributes(…)` call, because `.htmlAttributes` merges across
    /// stacked calls rather than the outer one losing to the inner (see
    /// ``HTMLAttributeBlock``). No extra wrapper element is needed just to
    /// give the marker somewhere to land.
    ///
    /// `.frame(maxWidth: .infinity)` on the wrapping `VStack` is load-
    /// bearing, not cosmetic: `HorizontalAlignment` has no `.stretch` case
    /// in this codebase (only leading/center/trailing), so a plain `VStack`
    /// shrinks to its content's width rather than filling whatever space
    /// its own parent offers. That's invisible for a viewport-width
    /// selector, but a `GeometrySelector(of:)` scoped to a `.container(_:)`
    /// needs its own subtree to actually claim the container's inline size
    /// — a container an author sized with `.frame(width:)` (or anything
    /// else) has nothing to report as its width if `GeometrySelector`
    /// itself collapses to its narrowest branch's content — browser-
    /// verified (headless Chrome): without this, a `.container(_:)`-marked
    /// ancestor measured 0px wide despite an explicit `.frame(width: 500)`
    /// immediately around it.
    private var staticBody: some View {
        registerGatingCSS()
        return VStack(spacing: 0) {
            ForEach(branches) { branch in
                branch.content
                    .htmlAttributes([branchMarkerAttribute: .set(markerValue(for: branch))])
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The measuring tier's arm: a `GeometryReader` selects and instantiates
    /// exactly one branch from the same declared ranges.
    ///
    /// `.containerWidth` branches can't be evaluated here — `GeometryProxy`
    /// exposes only the size proposed by the immediate parent, with no
    /// notion of a named ancestor container (documented on
    /// `GeometrySelector.Condition.containerWidth`) — so a container-scoped
    /// selector's measuring-tier arm always falls through to its fallback
    /// (or its last branch, absent one) rather than silently picking the
    /// first declared branch.
    private var measuringBody: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fallback = branches.first { $0.range == nil }
            // Construction-time validation guarantees at least one branch,
            // and a ranged branch whenever there's no fallback (the gap
            // check would otherwise have rejected it), so one of these three
            // always finds something.
            let selected =
                if containerName != nil {
                    fallback ?? branches[0]
                } else {
                    branches.first { branch in
                        guard let range = branch.range else { return false }
                        return range.contains(width)
                    } ?? fallback ?? branches[0]
                }
            selected.content
        }
    }

    /// The `data-gsel` value a branch's wrapper is marked with, and the
    /// attribute-selector value the registered CSS gates on. Combines the
    /// selector's own identity with the branch's declaration index, so two
    /// `GeometrySelector`s on one page never collide.
    private func markerValue(for branch: GSelBranch) -> String {
        "\(selectorID)-\(branch.id)"
    }

    /// Registers this selector's gating CSS: a hide-rule per ranged branch
    /// (fired OUTSIDE its own range) plus a hide-rule per branch for the
    /// fallback (fired INSIDE that branch's range) — everyone but the active
    /// branch is `display:none` at any given width.
    ///
    /// Registered as a single `.style` fragment item so its rules land after
    /// the interned stylesheet in source order (StaticHTMLRenderer's
    /// document assembly puts registered head contributions after the
    /// baseline `<style>` block specifically for this — see the note on
    /// `StaticHTMLRenderer.document`). Equal specificity between
    /// `[data-gsel]`'s `display:none` and an interned class's `display:flex`
    /// means source order is what decides the tie, so this rule has to be
    /// registered, not just present — inlining it earlier would lose the
    /// gate.
    ///
    /// Two different mechanisms for the two branch kinds, and they're not
    /// interchangeable:
    ///
    /// - A **ranged branch** hides itself under `condition.negatedCSSAtRule`
    ///   — the negation of its OWN declared range (see that property, and
    ///   `WidthRange.negatedCSSFeatures` for the parenthesization it
    ///   depends on). This has to be self-negation, not "hidden under every
    ///   other branch's at-rule": a width inside a GAP (nothing declared
    ///   covers it, which is exactly when a fallback is required) matches
    ///   NO other branch's at-rule at all, so under that scheme nothing
    ///   would hide this branch there and it would render alongside the
    ///   fallback. Browser-verified in headless Chrome, not theoretical.
    /// - The **fallback**, by contrast, correctly uses "hidden under every
    ///   OTHER branch's own at-rule" (per the ratified design) — no
    ///   complement computed from the other ranges. This works because the
    ///   fallback's rule doesn't need to characterize its own active region;
    ///   it only needs to disappear precisely where a declared branch
    ///   claims the width, which every declared branch's own at-rule
    ///   already states.
    private func registerGatingCSS() {
        guard let registry = environment.htmlFragmentRegistry else {
            return
        }
        let key = HTMLDocumentItem.DedupeKey.id(selectorID)
        guard !registry.contains(key) else {
            return
        }

        let ranged = branches.filter { $0.range != nil }
        let fallback = branches.first { $0.range == nil }

        // Deterministic order, matching the breakpoint design's documented
        // ordering rule for grouped at-rules: ascending by lower bound. Both
        // loops below walk branches in this order rather than declaration
        // order, so output doesn't depend on the order WidthCases happened
        // to be written in.
        let sortedRanged = ranged.sorted {
            ($0.range?.lowerBound ?? -.infinity) < ($1.range?.lowerBound ?? -.infinity)
        }

        func condition(for range: WidthRange) -> Condition {
            containerName.map { .containerWidth(name: $0, range: range) } ?? .viewportWidth(range)
        }

        var rules: [String] = []

        for branch in sortedRanged {
            guard let range = branch.range else { continue }
            rules.append(
                "\(condition(for: range).negatedCSSAtRule) { [\(branchMarkerAttribute)=\"\(markerValue(for: branch))\"] { display: none; } }"
            )
        }

        if let fallback {
            for branch in sortedRanged {
                guard let range = branch.range else { continue }
                rules.append(
                    "\(condition(for: range).cssAtRule) { [\(branchMarkerAttribute)=\"\(markerValue(for: fallback))\"] { display: none; } }"
                )
            }
        }

        registry.register(
            HTMLDocumentItem(
                key: key,
                slot: .head,
                content: .style(rules.joined(separator: "\n"))
            )
        )
    }
}
