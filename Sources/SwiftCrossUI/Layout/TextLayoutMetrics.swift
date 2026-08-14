/// The geometry of a laid-out run of text: how much room it takes, and where
/// its first and last baselines sit within that room.
///
/// The baselines are what ``VerticalAlignment/firstTextBaseline`` and
/// ``VerticalAlignment/lastTextBaseline`` align on, so a backend that reports
/// them from its own font engine gets text alignment that matches the platform
/// exactly.
public struct TextLayoutMetrics: Hashable, Sendable {
    /// The size the text occupies.
    public var size: SIMD2<Int>
    /// The distance from the top of ``size`` down to the baseline of the first
    /// line of text.
    public var firstBaseline: Double
    /// The distance from the top of ``size`` down to the baseline of the last
    /// line of text.
    ///
    /// Equal to ``firstBaseline`` for single-line text.
    public var lastBaseline: Double

    /// Creates text layout metrics.
    ///
    /// - Parameters:
    ///   - size: The size the text occupies.
    ///   - firstBaseline: The first line's baseline, measured down from the top
    ///     of `size`.
    ///   - lastBaseline: The last line's baseline, measured down from the top of
    ///     `size`.
    public init(size: SIMD2<Int>, firstBaseline: Double, lastBaseline: Double) {
        self.size = size
        self.firstBaseline = firstBaseline
        self.lastBaseline = lastBaseline
    }
}
