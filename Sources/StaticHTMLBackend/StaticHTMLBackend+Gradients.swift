import Foundation
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

extension StaticHTMLBackend:
    BackendFeatures.LinearGradients,
    BackendFeatures.RadialGradients,
    BackendFeatures.AngularGradients
{
    /// A gradient stop with its color resolved under both schemes.
    ///
    /// Each stop is a separate color, so scheme-variance is decided per stop
    /// rather than for the gradient as a whole: a gradient mixing a fixed
    /// brand color with a semantic one emits a literal for the first and a
    /// custom property only for the second. See ``ColorPalette``.
    public struct GradientStop: Hashable, Sendable {
        /// The stop's color under both schemes.
        public var color: SchemePair
        /// Where the stop sits along the gradient, from 0 to 1.
        public var location: Double

        /// Creates a gradient stop.
        ///
        /// - Parameters:
        ///   - color: The stop's color under both schemes.
        ///   - location: Where the stop sits along the gradient, from 0 to 1.
        public init(color: SchemePair, location: Double) {
            self.color = color
            self.location = location
        }
    }

    /// The geometry distinguishing the three gradient kinds.
    public enum GradientKind: Hashable, Sendable {
        /// A gradient interpolating along the line between two points.
        case linear(start: UnitPoint, end: UnitPoint)
        /// A gradient interpolating outwards from a center point.
        case radial(center: UnitPoint)
        /// A gradient interpolating around a center point.
        ///
        /// The angle is where the sweep begins, in degrees clockwise from the
        /// trailing direction.
        case angular(center: UnitPoint, startAngle: Double)
    }

    /// A widget holding a gradient fill.
    public final class GradientWidget: Widget {
        /// Which kind of gradient this is, and its geometry.
        public internal(set) var kind = GradientKind.linear(start: .top, end: .bottom)
        /// The gradient's color stops, in order.
        ///
        /// Already adjusted for the start radius or end angle where the view
        /// carried one — see ``SwiftCrossUI/RadialGradient/adjustedStops`` and
        /// ``SwiftCrossUI/AngularGradient/adjustedStops``, which express those
        /// as stop positions for backends with no native equivalent. CSS is
        /// one of them: `radial-gradient` has no inner radius, and
        /// `conic-gradient` no partial sweep.
        public internal(set) var stops: [GradientStop] = []
    }

    public func createLinearGradientWidget() -> Widget {
        GradientWidget()
    }

    public func updateLinearGradientWidget(
        _ widget: Widget,
        gradient: LinearGradient,
        withSize size: SIMD2<Int>,
        in environment: EnvironmentValues
    ) {
        let widget = widget as! GradientWidget
        widget.kind = .linear(start: gradient.startPoint, end: gradient.endPoint)
        update(widget, with: gradient.gradient.stops, in: environment)
    }

    public func createRadialGradientWidget() -> Widget {
        GradientWidget()
    }

    public func updateRadialGradientWidget(
        _ widget: Widget,
        gradient: RadialGradient,
        withSize size: SIMD2<Int>,
        in environment: EnvironmentValues
    ) {
        let widget = widget as! GradientWidget
        widget.kind = .radial(center: gradient.center)
        update(widget, with: gradient.adjustedStops, in: environment)
    }

    public func createAngularGradientWidget() -> Widget {
        GradientWidget()
    }

    public func updateAngularGradientWidget(
        _ widget: Widget,
        gradient: AngularGradient,
        withSize size: SIMD2<Int>,
        in environment: EnvironmentValues
    ) {
        let widget = widget as! GradientWidget
        widget.kind = .angular(
            center: gradient.center,
            startAngle: gradient.startAngle.degrees
        )
        update(widget, with: gradient.adjustedStops, in: environment)
    }

    /// Resolves a gradient's stops in this pass's scheme and stores them.
    ///
    /// - Parameters:
    ///   - widget: The widget to update.
    ///   - stops: The stops to resolve.
    ///   - environment: The environment to resolve the stops' colors against.
    private func update(
        _ widget: GradientWidget,
        with stops: [Gradient.Stop],
        in environment: EnvironmentValues
    ) {
        let existing = widget.stops
        widget.stops = stops.enumerated().map { index, stop in
            GradientStop(
                color: pair(
                    forResolved: stop.color.resolve(in: environment),
                    // Both passes walk the same gradient, so a stop keeps its
                    // index between them; that's what lets the second pass
                    // fill in the other scheme's half rather than starting a
                    // new pair.
                    existing: index < existing.count ? existing[index].color : nil
                ),
                location: stop.location
            )
        }
        widget.captureIntent(from: environment)
    }
}
