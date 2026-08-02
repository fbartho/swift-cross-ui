@_spi(Backends) import SwiftCrossUI

// Controls, split out from the main backend file to keep the core emit path
// readable.
//
// Static output has no event loop, so nothing here is interactive. Controls
// that have a meaningful still image (a checkbox's checked state, a slider's
// position, a text field's contents) are rendered as that image, with the
// handlers dropped. Controls whose only purpose is interaction, or which would
// need a widget type this backend doesn't model, call `fatalError` as
// CONTRIBUTING recommends for genuinely unsupported functionality.
extension StaticHTMLBackend {
    /// A checkbox, rendered in whichever state it was given.
    public class Checkbox: Widget {
        public var state = false

        override public var naturalSize: SIMD2<Int> {
            SIMD2(14, 14)
        }
    }

    /// A switch, rendered in whichever state it was given.
    public class Switch: Widget {
        public var state = false

        override public var naturalSize: SIMD2<Int> {
            SIMD2(28, 16)
        }
    }

    /// A toggle button, rendered in whichever state it was given.
    public class ToggleButton: Widget {
        public var label = ""
        public var state = false
        public var font: Font.Resolved?

        override public var naturalSize: SIMD2<Int> {
            guard let font else { return .zero }
            let characterHeight = Int(font.pointSize)
            let characterWidth = characterHeight * 2 / 3
            return SIMD2(
                characterWidth * label.count + 20,
                Int(font.lineHeight) + 10
            )
        }
    }

    /// A slider, rendered at whichever value it was given.
    public class Slider: Widget {
        public var value: Double = 0
        public var minimumValue: Double = 0
        public var maximumValue: Double = 100

        override public var naturalSize: SIMD2<Int> {
            SIMD2(100, 16)
        }
    }

    /// A text field, rendered showing its content or placeholder.
    public class TextField: Widget {
        public var isSecure: Bool
        public var value = ""
        public var placeholder = ""
        public var font: Font.Resolved?

        init(isSecure: Bool) {
            self.isSecure = isSecure
        }

        override public var naturalSize: SIMD2<Int> {
            guard let font else { return .zero }
            return SIMD2(150, Int(font.lineHeight) + 10)
        }
    }

    /// An image, rendered as an inlined data URL.
    public class ImageView: Widget {
        public var rgbaData: [UInt8] = []
        public var pixelWidth = 0
        public var pixelHeight = 0

        override public var naturalSize: SIMD2<Int> {
            SIMD2(pixelWidth, pixelHeight)
        }
    }

    // MARK: - Images

    public func createImageView() -> Widget {
        ImageView()
    }

    public func updateImageView(
        _ imageView: Widget,
        rgbaData: [UInt8],
        width: Int,
        height: Int,
        targetWidth: Int,
        targetHeight: Int,
        dataHasChanged: Bool,
        environment: EnvironmentValues
    ) {
        let imageView = imageView as! ImageView
        if dataHasChanged {
            imageView.rgbaData = rgbaData
            imageView.pixelWidth = width
            imageView.pixelHeight = height
        }
        imageView.captureIntent(from: environment)
    }

    // MARK: - Checkboxes

    public func createCheckbox() -> Widget {
        Checkbox()
    }

    public func updateCheckbox(
        _ checkboxWidget: Widget,
        environment: EnvironmentValues,
        onChange: @escaping (Bool) -> Void
    ) {
        checkboxWidget.captureIntent(from: environment)
    }

    public func setState(ofCheckbox checkboxWidget: Widget, to state: Bool) {
        (checkboxWidget as! Checkbox).state = state
    }

    // MARK: - Switches

    public func createSwitch() -> Widget {
        Switch()
    }

    public func updateSwitch(
        _ switchWidget: Widget,
        environment: EnvironmentValues,
        onChange: @escaping (Bool) -> Void
    ) {
        switchWidget.captureIntent(from: environment)
    }

    public func setState(ofSwitch switchWidget: Widget, to state: Bool) {
        (switchWidget as! Switch).state = state
    }

    // MARK: - Toggle buttons

    public func createToggle() -> Widget {
        ToggleButton()
    }

    public func updateToggle(
        _ toggle: Widget,
        label: String,
        environment: EnvironmentValues,
        onChange: @escaping (Bool) -> Void
    ) {
        let toggle = toggle as! ToggleButton
        toggle.label = label
        toggle.font = environment.resolvedFont
        toggle.captureIntent(from: environment)
    }

    public func setState(ofToggle toggle: Widget, to state: Bool) {
        (toggle as! ToggleButton).state = state
    }

    // MARK: - Sliders

    public func createSlider() -> Widget {
        Slider()
    }

    public func updateSlider(
        _ slider: Widget,
        minimum: Double,
        maximum: Double,
        decimalPlaces: Int,
        environment: EnvironmentValues,
        onChange: @escaping (Double) -> Void
    ) {
        let slider = slider as! Slider
        slider.minimumValue = minimum
        slider.maximumValue = maximum
        slider.captureIntent(from: environment)
    }

    public func setValue(ofSlider slider: Widget, to value: Double) {
        (slider as! Slider).value = value
    }

    // MARK: - Text fields

    public func createTextField() -> Widget {
        TextField(isSecure: false)
    }

    public func updateTextField(
        _ textField: Widget,
        placeholder: String,
        environment: EnvironmentValues,
        onChange: @escaping (String) -> Void,
        onSubmit: @escaping () -> Void
    ) {
        let textField = textField as! TextField
        textField.placeholder = placeholder
        textField.font = environment.resolvedFont
        textField.captureIntent(from: environment)
    }

    public func setContent(ofTextField textField: Widget, to content: String) {
        (textField as! TextField).value = content
    }

    public func getContent(ofTextField textField: Widget) -> String {
        (textField as! TextField).value
    }

    // MARK: - Secure fields

    public func createSecureField() -> Widget {
        TextField(isSecure: true)
    }

    public func updateSecureField(
        _ secureField: Widget,
        placeholder: String,
        environment: EnvironmentValues,
        onChange: @escaping (String) -> Void,
        onSubmit: @escaping () -> Void
    ) {
        updateTextField(
            secureField,
            placeholder: placeholder,
            environment: environment,
            onChange: onChange,
            onSubmit: onSubmit
        )
    }

    public func setContent(ofSecureField secureField: Widget, to content: String) {
        setContent(ofTextField: secureField, to: content)
    }

    public func getContent(ofSecureField secureField: Widget) -> String {
        getContent(ofTextField: secureField)
    }

    // MARK: - Unsupported in static output

    // These would each need either an event loop or a widget model this
    // backend doesn't have. Following CONTRIBUTING's guidance, they trap
    // rather than silently rendering something wrong, so that adding one later
    // is a deliberate act.

    public func createSelectableListView() -> Widget {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func updateSelectableListView(
        _ selectableListView: Widget,
        environment: EnvironmentValues
    ) {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func baseItemPadding(ofSelectableListView listView: Widget) -> EdgeInsets {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func minimumRowSize(ofSelectableListView listView: Widget) -> SIMD2<Int> {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func setItems(
        ofSelectableListView listView: Widget,
        to items: [Widget],
        withRowHeights rowHeights: [Int]
    ) {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func setSelectionHandler(
        forSelectableListView listView: Widget,
        to action: @escaping (Int) -> Void
    ) {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func setSelectedItem(ofSelectableListView listView: Widget, toItemAt index: Int?) {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func createPicker(style: BackendPickerStyle) -> Widget {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func updatePicker(
        _ picker: Widget,
        options: [String],
        environment: EnvironmentValues,
        onChange: @escaping (Int?) -> Void
    ) {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func setSelectedOption(ofPicker picker: Widget, to selectedOption: Int?) {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func createProgressBar() -> Widget {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func updateProgressBar(
        _ widget: Widget,
        progressFraction: Double?,
        environment: EnvironmentValues
    ) {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func createProgressSpinner() -> Widget {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func createTextEditor() -> Widget {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func updateTextEditor(
        _ textEditor: Widget,
        environment: EnvironmentValues,
        onChange: @escaping (String) -> Void
    ) {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func setContent(ofTextEditor textEditor: Widget, to content: String) {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }

    public func getContent(ofTextEditor textEditor: Widget) -> String {
        fatalError("\(Self.self): \(#function) not supported in static output")
    }
}
