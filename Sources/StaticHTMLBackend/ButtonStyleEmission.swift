import SwiftCrossUI

/// How ``SwiftCrossUI/ButtonStyle`` reaches the emitted document.
///
/// The static tier gives buttons an appearance of its own because the reset
/// flattens the user-agent one and a native backend's button takes its look
/// from the platform widget rather than from anything declared in Swift.
extension ButtonStyle {
    /// The class this style is emitted as.
    ///
    /// Part of the emitted contract: a page owner overriding the reset, or
    /// writing rules of their own against the output, needs the name the
    /// markup actually carries.
    var className: String {
        switch kind {
            case .bordered: "scui-btn-bordered"
            case .plain: "scui-btn-plain"
            case .borderless: "scui-btn-borderless"
        }
    }

    /// The total padding the emitted CSS adds around a button's label.
    ///
    /// The layout system sizes a button as label + padding, so what this
    /// returns has to agree with the `.scui-btn-*` rules the browser will
    /// apply, or the build-host estimate and the rendered box disagree. Those
    /// rules are written in `em`, which resolves against the button's own font
    /// size — hence the font parameter rather than a constant.
    ///
    /// - Parameter font: The font resolved for the button.
    /// - Returns: The total horizontal and vertical padding, in points.
    func padding(forFont font: Font.Resolved?) -> SIMD2<Int> {
        guard kind != .plain else {
            // `.scui-btn-plain` zeroes the padding the shared rule sets.
            return .zero
        }
        let em = font.map { Double($0.pointSize) } ?? Self.fallbackEm
        return SIMD2(
            Int((Self.horizontalPaddingEm * 2 * em).rounded()),
            Int((Self.verticalPaddingEm * 2 * em).rounded())
        )
    }

    /// The horizontal padding on one side, matching the emitted CSS.
    static let horizontalPaddingEm = 0.8
    /// The vertical padding on one side, matching the emitted CSS.
    static let verticalPaddingEm = 0.3
    /// The em size assumed when no font resolved, matching the reset's root
    /// font size.
    private static let fallbackEm = 16.0
}
