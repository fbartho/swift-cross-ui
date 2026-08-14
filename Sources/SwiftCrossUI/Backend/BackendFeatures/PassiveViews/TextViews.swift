extension BackendFeatures {
    /// Backend methods for text rendering.
    ///
    /// These are used by ``Text``, and occasionally other features as well.
    @MainActor
    public protocol TextViews: Core {
        /// Resolves the given text style to concrete font properties.
        ///
        /// This method doesn't take ``EnvironmentValues`` because its result
        /// should be consistent when given the same text style twice. Font
        /// modifiers take effect later in the font resolution process.
        ///
        /// A default implementation is provided. It uses the backend's reported
        /// device class and looks up the text style in a lookup table derived
        /// from Apple's typography guidelines.
        ///
        /// - SeeAlso: ``Font/TextStyle/resolve(for:)``
        ///
        /// - Parameter textStyle: The text style to resolve.
        /// - Returns: The resolved text style.
        func resolveTextStyle(_ textStyle: Font.TextStyle) -> Font.TextStyle.Resolved

        /// Gets the size that the given text would have if it were laid out while
        /// attempting to stay within the proposed frame.
        ///
        /// The size returned by this function will be upheld by the layout system;
        /// child views always get the final say on their own size, parents just
        /// choose how the children get laid out. The given text should be
        /// truncated/ellipsized to fit within the proposal if possible.
        ///
        /// SwiftCrossUI will never supply zero as the proposed width or height,
        /// because some UI frameworks handle that in special ways.
        ///
        /// Most backends only use the proposed width and ignore the proposed height.
        ///
        /// Used by both ``Text`` and ``TextEditor``.
        ///
        /// - Parameters:
        ///   - text: The text to get the size of.
        ///   - widget: The target widget. Some backends (such as GTK) require a
        ///     reference to the target widget to get a text layout context.
        ///   - proposedWidth: The proposed width of the text. If `nil`, the text
        ///     should take up as much height as necessary to respect the proposed
        ///     width without getting ellipsized.
        ///   - proposedHeight: The proposed height of the text.
        ///   - environment: The current environment.
        /// - Returns: The size of `text` if it were laid out while attempting to
        ///   stay within `proposedFrame`.
        func size(
            of text: String,
            whenDisplayedIn widget: Widget,
            proposedWidth: Int?,
            proposedHeight: Int?,
            environment: EnvironmentValues
        ) -> SIMD2<Int>

        /// Gets the size of the given text along with the position of its first
        /// and last baselines, for the same proposal
        /// ``size(of:whenDisplayedIn:proposedWidth:proposedHeight:environment:)``
        /// takes.
        ///
        /// The baselines are what ``VerticalAlignment/firstTextBaseline`` and
        /// ``VerticalAlignment/lastTextBaseline`` align on. A backend whose font
        /// engine reports real baselines should implement this; the default
        /// implementation derives them from the resolved font's metrics and the
        /// line count implied by the measured size, which is exact for backends
        /// whose line height matches the resolved font's and approximate
        /// otherwise.
        ///
        /// - Parameters:
        ///   - text: The text to measure.
        ///   - widget: The target widget, as for the size query.
        ///   - proposedWidth: The proposed width of the text.
        ///   - proposedHeight: The proposed height of the text.
        ///   - environment: The current environment.
        /// - Returns: The text's size and baselines.
        func layoutMetrics(
            ofText text: String,
            whenDisplayedIn widget: Widget,
            proposedWidth: Int?,
            proposedHeight: Int?,
            environment: EnvironmentValues
        ) -> TextLayoutMetrics

        /// Creates a non-editable text view with optional text wrapping.
        ///
        /// Predominantly used by ``Text``.
        ///
        /// The returned widget should truncate and ellipsize its content when
        /// given a size which isn't big enough to fit the full content, as per
        /// ``size(of:whenDisplayedIn:proposedWidth:proposedHeight:environment:)``.
        ///
        /// - Returns: A text view.
        func createTextView() -> Widget

        /// Sets the content and wrapping mode of a non-editable text view.
        ///
        /// - Parameters:
        ///   - textView: The text view.
        ///   - content: The text view's content.
        ///   - environment: The current environment.
        func updateTextView(
            _ textView: Widget,
            content: String,
            environment: EnvironmentValues
        )
    }
}

// MARK: Default Implementations

extension BackendFeatures.TextViews {
    public func resolveTextStyle(
        _ textStyle: Font.TextStyle
    ) -> Font.TextStyle.Resolved {
        textStyle.resolve(for: deviceClass)
    }

    public func layoutMetrics(
        ofText text: String,
        whenDisplayedIn widget: Widget,
        proposedWidth: Int?,
        proposedHeight: Int?,
        environment: EnvironmentValues
    ) -> TextLayoutMetrics {
        let size = size(
            of: text,
            whenDisplayedIn: widget,
            proposedWidth: proposedWidth,
            proposedHeight: proposedHeight,
            environment: environment
        )
        return TextLayoutMetrics(
            size: size,
            derivedFrom: environment.resolvedFont
        )
    }
}

extension TextLayoutMetrics {
    /// Derives baselines for a measured text size from the font's own metrics,
    /// for backends that don't report baselines themselves.
    ///
    /// The baseline of a line box sits at the font's ascent, which the resolved
    /// font doesn't carry; it is taken to be the point size plus the half of
    /// the leading that sits above the text, which is where it lands for fonts
    /// whose ascent and descent split the em box the conventional way.
    ///
    /// - Parameters:
    ///   - size: The measured size of the text.
    ///   - font: The font the text was measured in.
    init(size: SIMD2<Int>, derivedFrom font: Font.Resolved) {
        let lineHeight = max(font.lineHeight, 1)
        let leading = max(lineHeight - font.pointSize, 0)
        let ascent = font.pointSize + leading / 2

        // A measured height shorter than one line still holds one baseline;
        // anything taller is however many whole lines fit in it.
        let lineCount = max(1, (Double(size.y) / lineHeight).rounded(.down))

        self.init(
            size: size,
            firstBaseline: ascent,
            lastBaseline: (lineCount - 1) * lineHeight + ascent
        )
    }
}
