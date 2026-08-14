import SwiftCrossUI

/// A backend that can record an author's element name and attributes on one of
/// its widgets.
///
/// The escape-hatch modifiers that never leave their application site —
/// ``SwiftCrossUI/View/htmlTag(_:)`` and
/// ``SwiftCrossUI/View/htmlAttributes(_:)`` — anchor through this. The
/// modifier creates a wrapper widget, and its own node receives both that
/// widget and the environment in every core lifecycle call, so the value lands
/// on the element the author modified without propagating past it. Structure
/// is the identity: two applications are two nodes with two widgets, so a
/// `ForEach` body tagging every row needs nothing to tell the rows apart.
///
/// Only StaticHTMLBackend conforms. Under any other backend the modifier's
/// conditional cast fails and it degrades to a plain wrapper that renders its
/// content unchanged, which is what keeps a view hierarchy carrying these
/// modifiers portable.
@MainActor
public protocol HTMLElementAnchoring: BaseAppBackend {
    /// Records the element an author named for this widget.
    ///
    /// - Parameters:
    ///   - element: The element to emit the widget as.
    ///   - widget: The wrapper widget the modifier owns.
    func anchor(element: HTMLElement, to widget: Widget)

    /// Records a block of attribute operations an author attached to this
    /// widget.
    ///
    /// Where the block lands is decided during emission: a block naming an
    /// `id` materializes this widget's own element, and a block naming none
    /// rides down to the first element that survives elision. Both start
    /// here, on the widget whose view the author modified.
    ///
    /// - Parameters:
    ///   - attributes: The attribute operations to apply.
    ///   - widget: The wrapper widget the modifier owns.
    func anchor(attributes: HTMLAttributeBlock, to widget: Widget)
}

extension HTMLElementAnchoring {
    /// Records an element name on a widget known only as `Any`.
    ///
    /// The modifier reaches its backend as an existential — it is generic over
    /// every backend, and only this one can receive the value — so the widget
    /// arrives untyped and is matched to this backend here.
    ///
    /// - Parameters:
    ///   - element: The element to emit the widget as.
    ///   - widget: The widget, which does nothing unless it is this backend's.
    func anchor(element: HTMLElement, toAny widget: Any) {
        guard let widget = widget as? Widget else {
            return
        }
        anchor(element: element, to: widget)
    }

    /// Records an attribute block on a widget known only as `Any`, as
    /// ``anchor(element:toAny:)`` does for an element name.
    ///
    /// - Parameters:
    ///   - attributes: The attribute operations to apply.
    ///   - widget: The widget, which does nothing unless it is this backend's.
    func anchor(attributes: HTMLAttributeBlock, toAny widget: Any) {
        guard let widget = widget as? Widget else {
            return
        }
        anchor(attributes: attributes, to: widget)
    }
}
