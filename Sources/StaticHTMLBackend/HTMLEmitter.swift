import Foundation
import ImageFormats
@_spi(Backends) import SwiftCrossUI

/// Serializes a committed widget tree into HTML.
///
/// Element choice runs through three layers, in order:
///
/// 1. An explicit ``View/htmlTag(_:)`` on the view, which always wins.
/// 2. A heading derived from the author's declared text style, via
///    ``HeadingMap``.
/// 3. A `div` (or `span` for text) carrying an ARIA role where the widget's
///    type implies one.
///
/// Nothing outside those three layers gets to influence semantics. Geometry
/// and styling never do.
///
/// ## Flow, not coordinates
///
/// The layout system produces an exact position and size for every widget, but
/// emitting those directly would produce a document that only looks right at
/// the width it was laid out against: text that the browser wraps differently
/// than the build host estimated would overflow its pinned box, and nothing
/// would reflow when the reader resizes the window or opens the page on a
/// phone. This tier is what crawlers and readers without JavaScript get, so it
/// reflows.
///
/// Containers the layout system describes as stacks (see
/// ``StaticHTMLBackend/Container/stackLayout``) are therefore re-expressed as
/// CSS flex containers — direction, `gap`, and alignment carry the arrangement
/// — and their children take their natural size. The committed geometry is
/// still used where CSS has nothing to derive a size from, and absolute
/// positioning remains for containers that were never described as stacks,
/// which is the only construct flow can't express.
///
/// The result is best-effort: it drifts from the native rendering, which is
/// accepted. Overlapping or non-reflowing output is not.
@MainActor
public struct HTMLEmitter {
    /// The mapping from declared text styles to heading elements.
    public var headingMap: HeadingMap
    /// The interner that collapses duplicate styles into shared classes.
    public var interner = StyleInterner()
    /// The palette that turns scheme-varying colors into custom properties.
    public var palette = ColorPalette()

    /// How a parent is positioning one of its children.
    public enum Placement: Hashable, Sendable {
        /// The browser places the element, which is the usual case. The
        /// element's size comes from its content and from whatever the parent's
        /// flow rules impose.
        case flow
        /// The element is pinned to the coordinates the layout system committed
        /// for it. Used only where flow can't express the arrangement.
        case absolute
    }

    /// Creates an emitter.
    ///
    /// - Parameter headingMap: The mapping to derive headings with.
    public init(headingMap: HeadingMap = .default) {
        self.headingMap = headingMap
    }

    /// Emits a widget and its descendants.
    ///
    /// - Parameters:
    ///   - widget: The widget to emit.
    ///   - origin: The widget's position relative to its parent. Only consulted
    ///     when `placement` is ``Placement/absolute``; under flow the browser
    ///     decides where the element lands.
    ///   - placement: How the parent is positioning this widget.
    ///   - indentLevel: How far to indent the emitted markup.
    ///   - inheritedFrame: A size an enclosing frame declared for this widget
    ///     specifically, rather than for a wrapper around it. Only a void
    ///     element (``HTMLElement/isVoid``) honors this: those elements size
    ///     themselves from their replaced content, not from CSS layout, so a
    ///     frame around one has nothing to apply itself to except the element
    ///     directly. See ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:)``.
    /// - Returns: The widget's markup.
    public mutating func emit(
        _ widget: StaticHTMLBackend.Widget,
        at origin: SIMD2<Int>,
        placement: Placement = .flow,
        indentLevel: Int = 0,
        inheritedFrame: SIMD2<Int>? = nil
    ) -> String {
        let indent = String(repeating: "  ", count: indentLevel + 1)

        var style = Style()
        if placement == .absolute {
            style.set("absolute", for: "position")
            style.set("\(origin.x)px", for: "left")
            style.set("\(origin.y)px", for: "top")
            style.set("\(widget.size.x)px", for: "width")
            style.set("\(widget.size.y)px", for: "height")
        }
        if widget.cornerRadius > 0 {
            style.set("\(widget.cornerRadius)px", for: "border-radius")
        }

        var element = HTMLElement.div
        var role: String?
        var inner = ""
        var isRawInner = false
        // Attributes a control case needs beyond what every widget already
        // gets (role, data-scui, class, ...) — checked/value/min/max/etc.
        // Kept separate from `attributes` below so author attributes are
        // still merged first and can't be clobbered by a backend-owned one.
        var controlAttributes: [String: String] = [:]

        switch widget {
            case let text as StaticHTMLBackend.TextView:
                element = .span
                if let font = text.font {
                    style.set("\(Int(font.pointSize))px", for: "font-size")
                    style.set("\(Int(font.lineHeight))px", for: "line-height")
                    style.set(Self.cssWeight(font.weight), for: "font-weight")
                    if font.isItalic {
                        style.set("italic", for: "font-style")
                    }
                    if font.design == .monospaced {
                        style.set("monospace", for: "font-family")
                    }
                }
                if let color = text.color {
                    style.set(palette.value(for: color), for: "color")
                }
                style.set("pre-wrap", for: "white-space")
                inner = Self.escape(text.content)
                // A declared text style is the author saying what this line is
                // for, so it outranks the generic span.
                if let derived = headingMap.element(for: text.declaredFont) {
                    element = derived
                }

            case let button as StaticHTMLBackend.Button:
                // With no runtime there's nothing to click, so a button is
                // emitted as a link and given the role it plays.
                element = .custom("a")
                role = "button"
                style.set("inline-flex", for: "display")
                style.set("center", for: "align-items")
                style.set("center", for: "justify-content")
                style.set("none", for: "text-decoration")
                style.set("border-box", for: "box-sizing")
                inner = Self.escape(button.label)

            case let checkbox as StaticHTMLBackend.Checkbox:
                element = .custom("input")
                controlAttributes["type"] = "checkbox"
                controlAttributes["aria-checked"] = checkbox.state ? "true" : "false"
                if checkbox.state {
                    controlAttributes["checked"] = "checked"
                }
                style.set("14px", for: "width")
                style.set("14px", for: "height")

            case let toggleSwitch as StaticHTMLBackend.Switch:
                // HTML has no native switch input, so the standard
                // accessible pattern is a `role="switch"` on a focusable
                // element carrying `aria-checked`. `<button>` is the
                // natively-focusable choice; there is no click handler to
                // wire up, but the still image at least identifies as a
                // switch and reports its state to a screen reader.
                element = .custom("button")
                role = "switch"
                controlAttributes["type"] = "button"
                controlAttributes["aria-checked"] = toggleSwitch.state ? "true" : "false"
                style.set("28px", for: "width")
                style.set("16px", for: "height")

            case let toggleButton as StaticHTMLBackend.ToggleButton:
                element = .custom("button")
                controlAttributes["type"] = "button"
                controlAttributes["aria-pressed"] = toggleButton.state ? "true" : "false"
                if let font = toggleButton.font {
                    style.set("\(Int(font.pointSize))px", for: "font-size")
                    style.set("\(Int(font.lineHeight))px", for: "line-height")
                }
                inner = Self.escape(toggleButton.label)

            case let slider as StaticHTMLBackend.Slider:
                element = .custom("input")
                controlAttributes["type"] = "range"
                controlAttributes["min"] = Self.formatNumber(slider.minimumValue)
                controlAttributes["max"] = Self.formatNumber(slider.maximumValue)
                controlAttributes["value"] = Self.formatNumber(slider.value)
                style.set("100%", for: "width")

            case let textField as StaticHTMLBackend.TextField:
                element = .custom("input")
                controlAttributes["type"] = textField.isSecure ? "password" : "text"
                controlAttributes["value"] = textField.value
                if !textField.placeholder.isEmpty {
                    controlAttributes["placeholder"] = textField.placeholder
                }
                style.set("border-box", for: "box-sizing")
                if let font = textField.font {
                    style.set("\(Int(font.pointSize))px", for: "font-size")
                }

            case let rectangle as StaticHTMLBackend.Rectangle:
                if let color = rectangle.color {
                    style.set(palette.value(for: color), for: "background-color")
                }
                // A rectangle has nothing inside it to derive a size from, so
                // its committed size is the only thing standing between it and
                // collapsing to nothing.
                Self.pin(size: rectangle.size, in: &style, placement: placement)

            case let image as StaticHTMLBackend.ImageView:
                // <img> is a void element, so it's the one place a data URL
                // can carry the picture itself rather than a path to it: the
                // static tier has no server to host a separate file against.
                // PNG round-trips the source's RGBA losslessly, which matters
                // here since there's no author-chosen quality/format to defer
                // to.
                element = .custom("img")
                if !image.rgbaData.isEmpty, image.pixelWidth > 0, image.pixelHeight > 0 {
                    do {
                        let png = try ImageFormats.Image<RGBA>(
                            width: image.pixelWidth,
                            height: image.pixelHeight,
                            bytes: image.rgbaData
                        ).encodeToPNG()
                        controlAttributes["src"] =
                            "data:image/png;base64,\(Data(png).base64EncodedString())"
                    } catch {
                        // Encoding a well-formed in-memory RGBA buffer to PNG
                        // isn't expected to fail; if it does, a broken image
                        // icon with no src is more honest than silently
                        // dropping back to the empty div this replaces.
                    }
                }
                // No accessibility seam reaches Image (no
                // .accessibilityLabel modifier exists in SwiftCrossUI yet),
                // so alt text is only ever author-supplied via
                // .htmlAttributes(["alt": …]) — merged in below like any
                // other author attribute. Absent that, an empty alt is
                // still required: it's what marks the image decorative
                // rather than leaving assistive tech to read the filename
                // out of a missing attribute.
                controlAttributes["alt"] = image.authorAttributes["alt"] ?? ""
                // The size the layout system committed is the one the
                // browser should honor directly, the same reasoning as the
                // inheritedFrame branch below: a void element sizes itself
                // from its replaced content, not from CSS layout, so there's
                // nowhere else to put a declared size except the element
                // itself.
                if image.size.x > 0 {
                    style.set("\(image.size.x)px", for: "width")
                }
                if image.size.y > 0 {
                    style.set("\(image.size.y)px", for: "height")
                }

            case let container as StaticHTMLBackend.Container:
                inner = emitChildren(
                    of: container,
                    style: &style,
                    indent: indent,
                    indentLevel: indentLevel
                )
                isRawInner = true

            case let scroll as StaticHTMLBackend.ScrollContainer:
                style.set("auto", for: "overflow")
                Self.pin(size: scroll.size, in: &style, placement: placement)
                inner = emitChildren(
                    [(scroll.child, .zero)],
                    placement: .flow,
                    indent: indent,
                    indentLevel: indentLevel
                )
                isRawInner = true

            default:
                let children = widget.getChildren()
                if !children.isEmpty {
                    inner = emitChildren(
                        children.map { ($0, SIMD2<Int>.zero) },
                        placement: .flow,
                        indent: indent,
                        indentLevel: indentLevel
                    )
                    isRawInner = true
                }
        }

        // An explicit tag is the author overriding everything above.
        if let explicit = widget.explicitElement, explicit.isValid {
            element = explicit
        }

        // A void element is replaced content: the browser sizes it from
        // whatever it turns out to reference (an image file, for instance),
        // not from CSS layout. A frame the author declared around one has no
        // box to apply itself to except the element itself, since a wrapper
        // div does nothing to stretch replaced content to fill it.
        if element.isVoid, let inheritedFrame {
            style.set("\(inheritedFrame.x)px", for: "width")
            style.set("\(inheritedFrame.y)px", for: "height")
        }

        var attributes: [String: String] = [:]
        // Author attributes are merged first so that backend-owned ones
        // overwrite them rather than the other way around.
        for (name, value) in widget.authorAttributes
            where HTMLElement.isValidName(name) && !Self.reservedAttributes.contains(name)
        {
            attributes[name] = value
        }
        for (name, value) in controlAttributes {
            attributes[name] = value
        }
        if let role, attributes["role"] == nil {
            attributes["role"] = role
        }
        if element.name == "a" {
            // A disabled control's still image must not keep an activatable
            // target: an `href` makes it look reachable to a keyboard,
            // crawler, or assistive technology exactly like an enabled one
            // would, which is worse than the div this used to fall back to
            // when nothing was wired up at all.
            if widget.isEnabled {
                attributes["href"] = attributes["href"] ?? "#"
            } else {
                attributes["href"] = nil
            }
        }
        if !widget.isEnabled {
            // `disabled` is only defined for form-associated elements
            // (button/input); `<a>` communicates the same state by omitting
            // `href` instead, handled above. `aria-disabled` and `tabindex`
            // aren't element-specific, so every disabled control gets them
            // regardless of which of those two paths applies.
            if Self.disablableElementNames.contains(element.name) {
                attributes["disabled"] = "disabled"
            }
            attributes["aria-disabled"] = "true"
            attributes["tabindex"] = "-1"
        }
        if let tag = widget.tag {
            attributes["data-scui"] = tag
        }
        if let className = interner.className(for: style) {
            attributes["class"] = className
        }

        let renderedAttributes =
            attributes
                .sorted { $0.key < $1.key }
                .map { name, value in " \(name)=\"\(Self.escape(value))\"" }
                .joined()

        guard !element.isVoid else {
            return "\(indent)<\(element.name)\(renderedAttributes)>"
        }

        let body = isRawInner ? "\(inner)\(indent)" : inner
        return "\(indent)<\(element.name)\(renderedAttributes)>\(body)</\(element.name)>"
    }

    /// Emits a container's children, styling the container to arrange them.
    ///
    /// A container the layout system described as a stack becomes a flex
    /// container, so the browser redoes the arrangement at the reader's width.
    /// One it didn't describe — an overlay, or anything positioning children by
    /// hand — keeps the committed coordinates, since there's no flow rule that
    /// would reproduce them.
    private mutating func emitChildren(
        of container: StaticHTMLBackend.Container,
        style: inout Style,
        indent: String,
        indentLevel: Int
    ) -> String {
        // A size the author asked for is kept whatever else the container
        // turns out to be. Nothing else about a container's geometry survives
        // into the output, so this is the one place a fixed dimension can come
        // from: the author writing one down.
        if let width = container.declaredWidth {
            style.set("\(Int(width))px", for: "width")
        }
        if let height = container.declaredHeight {
            style.set("\(Int(height))px", for: "height")
        }
        // A flexible frame declares a range rather than a fixed size, which
        // CSS min/max-width/height express directly. `.infinity` means "no
        // ceiling", which is CSS's default absent the property, so it's
        // skipped rather than emitted as an invalid length.
        if let minWidth = container.declaredMinWidth, minWidth.isFinite {
            style.set("\(Int(minWidth))px", for: "min-width")
        }
        if let maxWidth = container.declaredMaxWidth, maxWidth.isFinite {
            style.set("\(Int(maxWidth))px", for: "max-width")
        }
        if let minHeight = container.declaredMinHeight, minHeight.isFinite {
            style.set("\(Int(minHeight))px", for: "min-height")
        }
        if let maxHeight = container.declaredMaxHeight, maxHeight.isFinite {
            style.set("\(Int(maxHeight))px", for: "max-height")
        }

        guard let stack = container.stackLayout else {
            // A single child inset from every edge is padding, which flow
            // expresses directly. The insets are exactly recoverable: the
            // child's offset gives the leading and top ones, and whatever of
            // the container it doesn't fill gives the other two.
            if container.children.count == 1 {
                let (child, position) = container.children[0]
                let trailing = container.size.x - child.size.x - position.x
                let bottom = container.size.y - child.size.y - position.y
                if position.x >= 0 && position.y >= 0 && trailing >= 0 && bottom >= 0 {
                    // A frame positions its child by alignment rather than by
                    // insetting it, so reading the leftover space as padding
                    // would double the width the author asked for. A flexible
                    // frame does this exactly as a strict one does, even when
                    // it only constrains a range rather than fixing a size.
                    let isFrame =
                        container.declaredWidth != nil || container.declaredHeight != nil
                            || container.declaredMinWidth != nil || container
                            .declaredMaxWidth != nil
                            || container.declaredMinHeight != nil
                            || container.declaredMaxHeight != nil
                    if !isFrame && (position != .zero || trailing != 0 || bottom != 0) {
                        style.set(
                            "\(position.y)px \(trailing)px \(bottom)px \(position.x)px",
                            for: "padding"
                        )
                    }
                    // The wrapper's own width/height (set above from
                    // declaredWidth/declaredHeight) size a normal child fine,
                    // but a void element ignores CSS layout entirely, so it
                    // also gets offered the frame directly; see
                    // ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:)``.
                    let inheritedFrame =
                        isFrame
                            ? SIMD2(
                                Int(container.declaredWidth ?? Double(container.size.x)),
                                Int(container.declaredHeight ?? Double(container.size.y))
                            ) : nil
                    return emitChildren(
                        container.children,
                        placement: .flow,
                        indent: indent,
                        indentLevel: indentLevel,
                        inheritedFrame: inheritedFrame
                    )
                }
            }

            // Children that overlap can only be described by their
            // coordinates: flow has no rule that would stack them on top of
            // each other. Everything else stays in flow, because a container
            // the author didn't pin shouldn't stop the page reflowing just
            // because this emitter doesn't recognise it.
            guard Self.childrenOverlap(container.children) else {
                return emitChildren(
                    container.children,
                    placement: .flow,
                    indent: indent,
                    indentLevel: indentLevel
                )
            }

            style.set("relative", for: "position")
            style.set(style.value(for: "width") ?? "\(container.size.x)px", for: "width")
            style.set(style.value(for: "height") ?? "\(container.size.y)px", for: "height")
            return emitChildren(
                container.children,
                placement: .absolute,
                indent: indent,
                indentLevel: indentLevel
            )
        }

        style.set("flex", for: "display")
        style.set(stack.orientation == .horizontal ? "row" : "column", for: "flex-direction")
        if stack.spacing != 0 && container.children.count > 1 {
            style.set("\(stack.spacing)px", for: "gap")
        }
        // The stack's alignment is across its axis, which is exactly what
        // align-items controls.
        style.set(Self.cssAlignment(stack.alignment), for: "align-items")

        return emitChildren(
            container.children,
            placement: .flow,
            indent: indent,
            indentLevel: indentLevel
        )
    }

    /// Emits a list of children, each on its own line.
    ///
    /// - Parameter inheritedFrame: A size to offer each child directly, for
    ///   the frame-around-a-void-element case; see
    ///   ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:)``.
    ///   Only meaningful when `children` holds exactly one widget — a frame
    ///   always wraps a single child — so passing it alongside more than one
    ///   would offer every sibling the same box, which is never correct.
    private mutating func emitChildren(
        _ children: [(widget: StaticHTMLBackend.Widget, position: SIMD2<Int>)],
        placement: Placement,
        indent: String,
        indentLevel: Int,
        inheritedFrame: SIMD2<Int>? = nil
    ) -> String {
        guard !children.isEmpty else {
            return ""
        }
        var output = "\n"
        for (childWidget, childPosition) in children {
            output += emit(
                childWidget,
                at: childPosition,
                placement: placement,
                indentLevel: indentLevel + 1,
                inheritedFrame: inheritedFrame
            )
            output += "\n"
        }
        return output
    }

    /// Gives an element the size the layout system committed for it.
    ///
    /// Only for content the browser can't size on its own. Applying this to
    /// text would be the pinning that keeps the document from reflowing.
    /// Under flow the size is a floor rather than a fixed value, so content
    /// that turns out larger in the browser grows the box instead of spilling
    /// out of it.
    nonisolated static func pin(
        size: SIMD2<Int>,
        in style: inout Style,
        placement: Placement
    ) {
        guard placement == .flow else {
            // The absolute branch has already set an exact width and height.
            return
        }
        style.set("\(size.x)px", for: "min-width")
        style.set("\(size.y)px", for: "min-height")
    }

    /// Whether any two of a container's children share area.
    ///
    /// Overlap is the one arrangement flow has no rule for, so it's what
    /// decides that a container has to keep its committed coordinates.
    nonisolated static func childrenOverlap(
        _ children: [(widget: StaticHTMLBackend.Widget, position: SIMD2<Int>)]
    ) -> Bool {
        for first in children.indices {
            for second in children.indices where second > first {
                let a = children[first]
                let b = children[second]
                let horizontal =
                    min(a.position.x + a.widget.size.x, b.position.x + b.widget.size.x)
                        - max(a.position.x, b.position.x)
                let vertical =
                    min(a.position.y + a.widget.size.y, b.position.y + b.widget.size.y)
                        - max(a.position.y, b.position.y)
                if horizontal > 0 && vertical > 0 {
                    return true
                }
            }
        }
        return false
    }

    /// Maps a stack's cross-axis alignment to its CSS equivalent.
    nonisolated static func cssAlignment(_ alignment: StackAlignment) -> String {
        switch alignment {
            case .leading: "flex-start"
            case .center: "center"
            case .trailing: "flex-end"
        }
    }

    /// Attributes that the backend owns and authors may not overwrite.
    ///
    /// `style` is absent from the emitted markup entirely (styling goes
    /// through interned classes), so letting an author set it would reintroduce
    /// exactly the inline styling this backend avoids.
    nonisolated static let reservedAttributes: Set<String> = ["style", "class", "data-scui"]

    /// Element names that support the native `disabled` attribute.
    ///
    /// `<a>` doesn't — its disabled semantics come from omitting `href`
    /// instead, handled separately above — so it's excluded here to avoid
    /// emitting an attribute the HTML spec doesn't define for it.
    nonisolated static let disablableElementNames: Set<String> = ["button", "input"]

    /// Formats a `Double` the way a numeric HTML attribute expects: no
    /// trailing `.0` for whole numbers, since `min`/`max`/`value` on
    /// `<input type=range>` are otherwise indistinguishable from an author
    /// having actually asked for a fractional bound.
    nonisolated static func formatNumber(_ value: Double) -> String {
        value == value.rounded() && value.isFinite
            ? String(Int(value))
            : String(value)
    }

    /// Maps a resolved font weight to its CSS numeric equivalent.
    nonisolated static func cssWeight(_ weight: Font.Weight) -> String {
        switch weight {
            case .ultraLight: "100"
            case .thin: "200"
            case .light: "300"
            case .regular: "400"
            case .medium: "500"
            case .semibold: "600"
            case .bold: "700"
            case .heavy: "800"
            case .black: "900"
        }
    }

    /// Escapes a string for inclusion in markup or an attribute value.
    ///
    /// - Parameter string: The string to escape.
    /// - Returns: The escaped string.
    public nonisolated static func escape(_ string: String) -> String {
        var output = ""
        output.reserveCapacity(string.count)
        for character in string {
            switch character {
                case "&": output += "&amp;"
                case "<": output += "&lt;"
                case ">": output += "&gt;"
                case "\"": output += "&quot;"
                case "'": output += "&#39;"
                default: output.append(character)
            }
        }
        return output
    }
}
