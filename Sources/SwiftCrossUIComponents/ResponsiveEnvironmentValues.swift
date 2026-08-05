import SwiftCrossUI

/// Whether the reader has requested reduced motion at the OS level.
///
/// The web analogue of SwiftUI's `accessibilityReduceMotion`. Kept as its
/// own type (not a bare `Bool`) so a later tier that can distinguish
/// "reduce" from "eliminate" (`prefers-reduced-motion: reduce` is the only
/// value the media feature defines today, but the type shouldn't foreclose
/// a finer answer if the platform ever adds one) has somewhere to put it
/// without a source-breaking change to the environment key's type.
public enum ReducedMotionPreference: Hashable, Sendable {
    /// No preference expressed, or motion is fine.
    case noPreference
    /// The reader asked for reduced motion.
    case reduced
}

/// The pointer input capability of the reader's primary input mechanism.
///
/// The web analogue of the CSS `pointer` media feature, which this maps
/// onto directly (coarse touch, fine mouse/trackpad, or no pointer at all —
/// a keyboard- or switch-only device).
public enum PointerCapability: Hashable, Sendable {
    /// A coarse pointer (touch) is the primary input, per CSS `(pointer: coarse)`.
    case coarse
    /// A fine pointer (mouse, trackpad, stylus) is the primary input, per
    /// CSS `(pointer: fine)`.
    case fine
    /// No pointing device at all, per CSS `(pointer: none)`.
    case none
}

extension EnvironmentValues {
    /// Whether the reader has requested reduced motion.
    ///
    /// **Static tier semantics (StaticHTMLBackend, the only backend that
    /// populates this today):** the build host renders once and has no
    /// reader to ask, so this is unconditionally ``ReducedMotionPreference/noPreference``
    /// — an honest "unknown, assume the common case" default, the same
    /// stance ``deviceClass`` takes for a property no build-time render can
    /// measure. This is the MEASURING-tier half of
    /// `GeometrySelector.Condition`'s eventual `.reducedMotion` case (per
    /// the breakpoint design's both-halves rule): the CSS half is
    /// `@media (prefers-reduced-motion: reduce)`, evaluated by the browser
    /// at read time regardless of what this environment value says; this
    /// value exists for view-tree logic that wants to branch on the
    /// preference directly (skip constructing an animation-heavy subtree,
    /// say) rather than only being able to express it as a CSS condition.
    @Entry public var reducedMotion: ReducedMotionPreference = .noPreference

    /// The pointer capability of the reader's primary input mechanism.
    ///
    /// **Static tier semantics:** unconditionally ``PointerCapability/fine``,
    /// the safest assumption for a build-time render with no reader to
    /// measure — most StaticHTMLBackend readers browsing with JavaScript
    /// disabled or not yet hydrated are on a desktop crawler or a reader
    /// with a mouse/trackpad, and a `.fine` default doesn't suppress
    /// touch-friendly sizing the way a wrong `.coarse` default would
    /// suppress desktop-density layouts. As with ``reducedMotion``, this is
    /// the measuring-tier half of a future `GeometrySelector.Condition`
    /// case; the CSS half is `@media (pointer: coarse)` / `(pointer: fine)`
    /// / `(pointer: none)`, evaluated by the browser directly.
    @Entry public var pointerCapability: PointerCapability = .fine

    /// Whether the document is currently being printed or previewed for
    /// print.
    ///
    /// **Semantics, everywhere, not just the static tier:** always `false`.
    /// This isn't a static-tier gap the way ``reducedMotion`` and
    /// ``pointerCapability`` are — no SwiftCrossUI backend, live or static,
    /// has a print context to report, so there is no live-tier answer this
    /// default falls short of. The CSS half is real regardless:
    /// `@media print`, evaluated by the browser only inside an actual print
    /// preview, independent of whatever this environment value says. The
    /// motivating use case — a resume builder tightening layout and spacing
    /// for print — is served by that CSS condition alone, without this
    /// environment value ever needing to be `true`.
    @Entry public var printActive: Bool = false
}
