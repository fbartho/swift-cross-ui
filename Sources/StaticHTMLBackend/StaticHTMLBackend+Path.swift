import Foundation
@_spi(Backends) import SwiftCrossUI

extension StaticHTMLBackend: BackendFeatures.Paths {
    /// A path accumulated for a ``SwiftCrossUI/Shape``.
    ///
    /// The backend receives shapes as flattened ``SwiftCrossUI/Path/Action``
    /// lists rather than as the view that produced them: ``SwiftCrossUI/Shape``
    /// calls `path(in:)` before handing anything to a backend, so a
    /// ``SwiftCrossUI/Capsule`` and a hand-rolled ``SwiftCrossUI/Path`` of the
    /// same outline are indistinguishable here. That is what rules out
    /// expressing the built-in shapes as `border-radius` — no seam carries
    /// which shape a given action list came from — and what makes SVG path
    /// data the honest target: it represents whatever the actions describe,
    /// including shapes SwiftCrossUI doesn't ship.
    public final class Path {
        /// The path's geometry, as an SVG `d` attribute.
        var pathData = ""
        /// The stroke style the source path declared, which
        /// ``StaticHTMLBackend/renderPath(_:container:strokeColor:fillColor:overrideStrokeStyle:)``
        /// may override.
        var strokeStyle = StrokeStyle(width: 1.0)
        /// The fill rule the source path declared.
        var fillRule = FillRule.evenOdd
        /// The environment the path was last updated in.
        ///
        /// Authored intent (``View/htmlTag(_:)`` and friends) is read from the
        /// environment, and only ``StaticHTMLBackend/updatePath(_:_:bounds:pointsChanged:environment:)``
        /// receives one — the widget it belongs to is reachable only from
        /// ``StaticHTMLBackend/renderPath(_:container:strokeColor:fillColor:overrideStrokeStyle:)``,
        /// which doesn't.
        var environment: EnvironmentValues?
    }

    /// A widget holding a rendered path.
    public final class PathWidget: Widget {
        /// The path's geometry, as an SVG `d` attribute.
        public internal(set) var pathData = ""
        /// The color the path's interior is shaded with.
        public internal(set) var fillColor: SchemePair?
        /// The color the path's outline is drawn in.
        public internal(set) var strokeColor: SchemePair?
        /// The width of the path's outline.
        public internal(set) var strokeWidth = 0.0
        /// The shape drawn at the ends of an open subpath.
        public internal(set) var strokeCap = StrokeCap.butt
        /// The shape drawn where two segments meet.
        public internal(set) var strokeJoin = StrokeJoin.miter(limit: 10.0)
        /// The rule deciding which regions of the path count as interior.
        public internal(set) var fillRule = FillRule.evenOdd
    }

    public func createPathWidget() -> Widget {
        PathWidget()
    }

    public func createPath() -> Path {
        Path()
    }

    public func updatePath(
        _ path: Path,
        _ source: SwiftCrossUI.Path,
        bounds: SwiftCrossUI.Path.Rect,
        pointsChanged: Bool,
        environment: EnvironmentValues
    ) {
        path.strokeStyle = source.strokeStyle
        path.fillRule = source.fillRule
        path.environment = environment
        guard pointsChanged else {
            return
        }
        path.pathData = Self.pathData(for: source.actions)
    }

    public func renderPath(
        _ path: Path,
        container: Widget,
        strokeColor: Color.Resolved,
        fillColor: Color.Resolved,
        overrideStrokeStyle: StrokeStyle?
    ) {
        let widget = container as! PathWidget
        let strokeStyle = overrideStrokeStyle ?? path.strokeStyle

        widget.pathData = path.pathData
        widget.fillRule = path.fillRule
        widget.fillColor = pair(forResolved: fillColor, existing: widget.fillColor)
        widget.strokeColor = pair(forResolved: strokeColor, existing: widget.strokeColor)
        widget.strokeWidth = strokeStyle.width
        widget.strokeCap = strokeStyle.cap
        widget.strokeJoin = strokeStyle.join
        if let environment = path.environment {
            widget.captureIntent(from: environment)
        }
    }
}

extension StaticHTMLBackend {
    /// Converts path actions into an SVG `d` attribute.
    ///
    /// - Parameter actions: The actions to convert.
    /// - Returns: The path's geometry as SVG path data.
    nonisolated static func pathData(for actions: [SwiftCrossUI.Path.Action]) -> String {
        var builder = SVGPathBuilder()
        builder.append(actions)
        return builder.pathData
    }
}

/// Accumulates ``SwiftCrossUI/Path/Action`` values as SVG path data.
///
/// SVG has no transform operator inside path data and no primitive for a whole
/// circle, so the two actions that rely on those — `.transform` and `.circle` —
/// are resolved arithmetically here rather than deferred to the renderer: points
/// are transformed as they are written, and a circle becomes two half-arcs.
struct SVGPathBuilder {
    /// The path data accumulated so far.
    private(set) var pathData = ""
    /// The transform applied to points as they are written.
    ///
    /// ``SwiftCrossUI/Path/Action/transform(_:)`` applies to the segments drawn
    /// *before* it, so the builder rewrites the accumulated data when one
    /// arrives rather than carrying a running matrix forward.
    private var currentPoint = SIMD2<Double>.zero

    /// Appends a list of actions.
    ///
    /// - Parameter actions: The actions to append.
    mutating func append(_ actions: [SwiftCrossUI.Path.Action]) {
        for action in actions {
            append(action)
        }
    }

    /// Appends a single action.
    ///
    /// - Parameter action: The action to append.
    mutating func append(_ action: SwiftCrossUI.Path.Action) {
        switch action {
            case .moveTo(let point):
                write("M \(Self.number(point.x)) \(Self.number(point.y))")
                currentPoint = point
            case .lineTo(let point):
                write("L \(Self.number(point.x)) \(Self.number(point.y))")
                currentPoint = point
            case .quadCurve(let control, let end):
                write(
                    "Q \(Self.number(control.x)) \(Self.number(control.y))"
                        + " \(Self.number(end.x)) \(Self.number(end.y))"
                )
                currentPoint = end
            case .cubicCurve(let control1, let control2, let end):
                write(
                    "C \(Self.number(control1.x)) \(Self.number(control1.y))"
                        + " \(Self.number(control2.x)) \(Self.number(control2.y))"
                        + " \(Self.number(end.x)) \(Self.number(end.y))"
                )
                currentPoint = end
            case .rectangle(let rect):
                write(
                    "M \(Self.number(rect.x)) \(Self.number(rect.y))"
                        + " H \(Self.number(rect.maxX))"
                        + " V \(Self.number(rect.maxY))"
                        + " H \(Self.number(rect.x)) Z"
                )
                currentPoint = rect.origin
            case .circle(let center, let radius):
                // SVG's arc command can't describe a full turn — start and end
                // coincide, which it draws as nothing — so a circle is two
                // half-turns through the diametrically opposite point.
                let left = center.x - radius
                let right = center.x + radius
                write(
                    "M \(Self.number(left)) \(Self.number(center.y))"
                        + " A \(Self.number(radius)) \(Self.number(radius)) 0 1 1"
                        + " \(Self.number(right)) \(Self.number(center.y))"
                        + " A \(Self.number(radius)) \(Self.number(radius)) 0 1 1"
                        + " \(Self.number(left)) \(Self.number(center.y)) Z"
                )
                currentPoint = SIMD2(x: left, y: center.y)
            case .arc(let center, let radius, let startAngle, let endAngle, let clockwise):
                appendArc(
                    center: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: clockwise
                )
            case .transform(let transform):
                apply(transform)
            case .subpath(let actions):
                var subpath = SVGPathBuilder()
                subpath.append(actions)
                write(subpath.pathData)
        }
    }

    /// Appends an arc segment.
    ///
    /// - Parameters:
    ///   - center: The center of the arc's circle.
    ///   - radius: The radius of the arc's circle.
    ///   - startAngle: The angle the arc starts at, in radians.
    ///   - endAngle: The angle the arc ends at, in radians.
    ///   - clockwise: Whether the arc is drawn clockwise.
    private mutating func appendArc(
        center: SIMD2<Double>,
        radius: Double,
        startAngle: Double,
        endAngle: Double,
        clockwise: Bool
    ) {
        let start = SIMD2(
            x: center.x + radius * cos(startAngle),
            y: center.y + radius * sin(startAngle)
        )
        let end = SIMD2(
            x: center.x + radius * cos(endAngle),
            y: center.y + radius * sin(endAngle)
        )

        // A shape's path is a single connected outline, so an arc that doesn't
        // start where the previous segment ended needs a line closing the gap —
        // except at the very start of a path, where there is nothing to join to.
        if pathData.isEmpty {
            write("M \(Self.number(start.x)) \(Self.number(start.y))")
        } else if !Self.isClose(currentPoint, start) {
            write("L \(Self.number(start.x)) \(Self.number(start.y))")
        }

        var sweep = clockwise ? endAngle - startAngle : startAngle - endAngle
        while sweep < 0 {
            sweep += 2 * .pi
        }
        // A sweep of a full turn or more can't be expressed as one arc command
        // (start and end coincide), and core's own precondition keeps both
        // angles within a single turn, so the difference is halved instead.
        if sweep >= 2 * .pi - Self.angleEpsilon {
            let middleAngle = startAngle + (clockwise ? sweep / 2 : -sweep / 2)
            let middle = SIMD2(
                x: center.x + radius * cos(middleAngle),
                y: center.y + radius * sin(middleAngle)
            )
            let flag = clockwise ? "1" : "0"
            write(
                "A \(Self.number(radius)) \(Self.number(radius)) 0 0 \(flag)"
                    + " \(Self.number(middle.x)) \(Self.number(middle.y))"
                    + " A \(Self.number(radius)) \(Self.number(radius)) 0 0 \(flag)"
                    + " \(Self.number(end.x)) \(Self.number(end.y))"
            )
        } else {
            let largeArc = sweep > .pi ? "1" : "0"
            let flag = clockwise ? "1" : "0"
            write(
                "A \(Self.number(radius)) \(Self.number(radius)) 0 \(largeArc) \(flag)"
                    + " \(Self.number(end.x)) \(Self.number(end.y))"
            )
        }
        currentPoint = end
    }

    /// Applies a transform to everything drawn so far.
    ///
    /// - Parameter transform: The transform to apply.
    private mutating func apply(_ transform: SwiftCrossUI.AffineTransform) {
        guard !pathData.isEmpty else {
            return
        }
        // SVG applies a transform via an element attribute, which would cover
        // the whole path rather than only the segments preceding this action.
        // Re-parsing the accumulated data and mapping its coordinates keeps the
        // action's documented scope: a transform inside a path affects what came
        // before it and nothing after.
        pathData = Self.transformingCoordinates(in: pathData, by: transform)
        currentPoint = Self.apply(transform, to: currentPoint)
    }

    /// Appends a command, separating it from the previous one.
    ///
    /// - Parameter command: The command to append.
    private mutating func write(_ command: String) {
        guard !command.isEmpty else {
            return
        }
        if pathData.isEmpty {
            pathData = command
        } else {
            pathData += " \(command)"
        }
    }

    /// Applies a transform to a point.
    ///
    /// - Parameters:
    ///   - transform: The transform to apply.
    ///   - point: The point to transform.
    /// - Returns: The transformed point.
    static func apply(
        _ transform: SwiftCrossUI.AffineTransform,
        to point: SIMD2<Double>
    ) -> SIMD2<Double> {
        SIMD2(
            x: transform.linearTransform.x * point.x + transform.linearTransform.y * point.y
                + transform.translation.x,
            y: transform.linearTransform.z * point.x + transform.linearTransform.w * point.y
                + transform.translation.y
        )
    }

    /// Rewrites path data with every coordinate pair transformed.
    ///
    /// - Parameters:
    ///   - pathData: The path data to rewrite.
    ///   - transform: The transform to apply.
    /// - Returns: The transformed path data.
    private static func transformingCoordinates(
        in pathData: String,
        by transform: SwiftCrossUI.AffineTransform
    ) -> String {
        var output: [String] = []
        var pending: [Double] = []
        var command: Character?

        // An arc's first three parameters are radii and flags rather than a
        // coordinate pair, so they can't go through the point transform. Radii
        // scale by the transform's linear part; the flags and rotation are
        // rewritten from the transformed geometry's handedness.
        func flushArc() {
            guard pending.count == 7 else {
                pending = []
                return
            }
            let radii = SIMD2(x: pending[0], y: pending[1])
            let scaleX = (SIMD2(x: transform.linearTransform.x, y: transform.linearTransform.z))
            let scaleY = (SIMD2(x: transform.linearTransform.y, y: transform.linearTransform.w))
            let scaledRadii = SIMD2(
                x: radii.x * (scaleX.x * scaleX.x + scaleX.y * scaleX.y).squareRoot(),
                y: radii.y * (scaleY.x * scaleY.x + scaleY.y * scaleY.y).squareRoot()
            )
            let determinant =
                transform.linearTransform.x * transform.linearTransform.w
                    - transform.linearTransform.y * transform.linearTransform.z
            let sweep = determinant < 0 ? (pending[4] == 1 ? 0.0 : 1.0) : pending[4]
            let end = apply(transform, to: SIMD2(x: pending[5], y: pending[6]))
            output.append(number(scaledRadii.x))
            output.append(number(scaledRadii.y))
            output.append(number(pending[2]))
            output.append(number(pending[3]))
            output.append(number(sweep))
            output.append(number(end.x))
            output.append(number(end.y))
            pending = []
        }

        func flushPoints() {
            var index = 0
            while index + 1 < pending.count {
                let transformed = apply(
                    transform,
                    to: SIMD2(x: pending[index], y: pending[index + 1])
                )
                output.append(number(transformed.x))
                output.append(number(transformed.y))
                index += 2
            }
            pending = []
        }

        func flush() {
            guard let command else {
                pending = []
                return
            }
            if command == "A" {
                flushArc()
            } else {
                flushPoints()
            }
        }

        for token in pathData.split(separator: " ") {
            if let value = Double(token) {
                pending.append(value)
                if command == "A" && pending.count == 7 {
                    flushArc()
                }
                continue
            }
            flush()
            // H and V carry a single coordinate on one axis, which a transform
            // can move off that axis entirely; they're promoted to L so the
            // transformed point stays expressible.
            let letter = Character(String(token))
            switch letter {
                case "H", "V":
                    command = "L"
                    output.append("L")
                default:
                    command = letter
                    output.append(String(letter))
            }
        }
        flush()

        return output.joined(separator: " ")
    }

    /// Whether two points are near enough to need no joining segment.
    ///
    /// - Parameters:
    ///   - first: The first point.
    ///   - second: The second point.
    /// - Returns: Whether the points coincide.
    private static func isClose(_ first: SIMD2<Double>, _ second: SIMD2<Double>) -> Bool {
        abs(first.x - second.x) < 1e-9 && abs(first.y - second.y) < 1e-9
    }

    /// The tolerance for treating a sweep as a full turn.
    private static let angleEpsilon = 1e-9

    /// Formats a coordinate for SVG path data.
    ///
    /// - Parameter value: The value to format.
    /// - Returns: The value with no trailing zeroes.
    static func number(_ value: Double) -> String {
        guard value.isFinite else {
            return "0"
        }
        // Three decimal places is finer than a device pixel at any plausible
        // zoom, and rounding here keeps values that differ only by floating
        // point noise interning to the same path data.
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(rounded)
    }
}
