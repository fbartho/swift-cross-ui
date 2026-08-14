import SwiftCrossUI

/// A backend that can record an author's element name and attributes on one of
/// its widgets.
///
/// The escape-hatch modifiers that never leave their application site —
/// ``SwiftCrossUI/View/htmlTag(_:)`` and
/// ``SwiftCrossUI/View/htmlAttributes(_:)`` — capture through this rather than
/// putting their values in the environment. The modifier already creates a
/// wrapper widget, and its own node receives both that widget and the
/// environment in every core lifecycle call, so the value can land on the
/// element the author modified without ever propagating past it. Structure is
/// then the identity: two applications are two nodes with two widgets, so a
/// `ForEach` body tagging every row needs nothing to tell the rows apart.
///
/// Only StaticHTMLBackend conforms. Under any other backend the modifier's
/// conditional cast fails and it degrades to a plain wrapper that renders its
/// content unchanged, which is what keeps a view hierarchy carrying these
/// modifiers portable.
@MainActor
public protocol HTMLElementCapturing: BaseAppBackend {
    /// Records the element an author named for this widget.
    ///
    /// - Parameters:
    ///   - widget: The wrapper widget the modifier owns.
    ///   - element: The element to emit the widget as.
    func captureElement(of widget: Widget, as element: HTMLElement)

    /// Records a block of attribute operations an author attached to this
    /// widget.
    ///
    /// Where the block lands is decided during emission: a block naming an
    /// `id` materializes this widget's own element, and a block naming none
    /// rides down to the first element that survives elision. Both start
    /// here, on the widget whose view the author modified.
    ///
    /// - Parameters:
    ///   - widget: The wrapper widget the modifier owns.
    ///   - block: The attribute operations to apply.
    func captureAttributes(of widget: Widget, to block: HTMLAttributeBlock)
}

extension HTMLElementCapturing {
    /// Records an element name on a widget known only as `Any`.
    ///
    /// The modifier reaches its backend as an existential — it is generic over
    /// every backend, and only this one can receive the value — so the widget
    /// arrives untyped and is matched to this backend here.
    ///
    /// - Parameters:
    ///   - widget: The widget, which does nothing unless it is this backend's.
    ///   - element: The element to emit the widget as.
    func captureElement(ofAny widget: Any, as element: HTMLElement) {
        guard let widget = widget as? Widget else {
            return
        }
        captureElement(of: widget, as: element)
    }

    /// Records an attribute block on a widget known only as `Any`, as
    /// ``captureElement(ofAny:as:)`` does for an element name.
    ///
    /// - Parameters:
    ///   - widget: The widget, which does nothing unless it is this backend's.
    ///   - block: The attribute operations to apply.
    func captureAttributes(ofAny widget: Any, to block: HTMLAttributeBlock) {
        guard let widget = widget as? Widget else {
            return
        }
        captureAttributes(of: widget, to: block)
    }
}
