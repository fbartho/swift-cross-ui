import DummyBackend

@testable @_spi(Backends) import SwiftCrossUI

/// A reproducible random source, so a failing case can be re-run from its seed
/// alone.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Any nonzero state will do; xorshift stalls at zero.
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        if state == 0 {
            state = 0x9E37_79B9_7F4A_7C15
        }
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// The committed geometry of one widget subtree: what every position and size
/// in the tree came out as.
///
/// Compared wholesale, so a reduction failure anywhere in a generated tree
/// surfaces rather than only at the root.
struct GeometrySnapshot: Equatable, CustomStringConvertible {
    var size: SIMD2<Int>
    var position: SIMD2<Int>
    var children: [GeometrySnapshot]

    var description: String {
        description(indent: 0)
    }

    private func description(indent: Int) -> String {
        let padding = String(repeating: "  ", count: indent)
        let head = "\(padding)at \(position.x),\(position.y) size \(size.x)x\(size.y)"
        let body = children.map { $0.description(indent: indent + 1) }
        return ([head] + body).joined(separator: "\n")
    }
}

/// Captures a widget tree's committed geometry.
///
/// - Parameters:
///   - widget: The root of the tree.
///   - position: The position the root's own parent placed it at.
/// - Returns: The tree's geometry.
@MainActor
func geometryTree(
    of widget: DummyBackend.Widget,
    at position: SIMD2<Int> = .zero
) -> GeometrySnapshot {
    let children: [GeometrySnapshot]
    if let container = widget as? DummyBackend.Container {
        children = container.children.map { child, childPosition in
            geometryTree(of: child, at: childPosition)
        }
    } else {
        children = widget.getChildren().map { child in
            geometryTree(of: child)
        }
    }
    return GeometrySnapshot(
        size: widget.size,
        position: position,
        children: children
    )
}

/// A view tree built only from guide-free views, so that laying it out
/// exercises the reduction case.
///
/// Deliberately not an enum of shapes the layout system special-cases: the
/// point is ordinary trees, generated in shapes nobody chose by hand.
indirect enum GeneratedView {
    case leaf(width: Double, height: Double)
    case text(String)
    case vStack(alignment: HorizontalAlignment, spacing: Int, children: [GeneratedView])
    case hStack(alignment: VerticalAlignment, spacing: Int, children: [GeneratedView])
    case zStack(alignment: Alignment, children: [GeneratedView])
    case padded(GeneratedView, EdgeInsets)
    case framed(GeneratedView, width: Double?, height: Double?, alignment: Alignment)
    case fixed(GeneratedView)
}

extension GeneratedView {
    /// The subviews this node contains, for feeding a layout rule directly.
    var generatedChildren: [GeneratedView] {
        switch self {
            case .leaf, .text:
                []
            case .vStack(_, _, let children),
                 .hStack(_, _, let children),
                 .zStack(_, let children):
                children
            case .padded(let child, _),
                 .framed(let child, _, _, _),
                 .fixed(let child):
                [child]
        }
    }
}

/// Builds a random guide-free view tree.
///
/// - Parameters:
///   - depth: How many more levels of container may be nested. At zero only
///     leaves are produced.
///   - generator: The random source.
/// - Returns: A tree containing no alignment guides.
func randomTree(
    depth: Int,
    using generator: inout SeededGenerator
) -> GeneratedView {
    let horizontalAlignments: [HorizontalAlignment] = [.leading, .center, .trailing]
    let verticalAlignments: [VerticalAlignment] = [.top, .center, .bottom]

    guard depth > 0 else {
        return Bool.random(using: &generator)
            ? .leaf(
                width: Double(Int.random(in: 1...60, using: &generator)),
                height: Double(Int.random(in: 1...60, using: &generator))
            )
            : .text(String(repeating: "a ", count: Int.random(in: 1...6, using: &generator)))
    }

    func randomChildren() -> [GeneratedView] {
        (0..<Int.random(in: 1...3, using: &generator)).map { _ in
            randomTree(depth: depth - 1, using: &generator)
        }
    }

    switch Int.random(in: 0...6, using: &generator) {
        case 0:
            return .vStack(
                alignment: horizontalAlignments.randomElement(using: &generator)!,
                spacing: Int.random(in: 0...12, using: &generator),
                children: randomChildren()
            )
        case 1:
            return .hStack(
                alignment: verticalAlignments.randomElement(using: &generator)!,
                spacing: Int.random(in: 0...12, using: &generator),
                children: randomChildren()
            )
        case 2:
            return .zStack(
                alignment: Alignment(
                    horizontal: horizontalAlignments.randomElement(using: &generator)!,
                    vertical: verticalAlignments.randomElement(using: &generator)!
                ),
                children: randomChildren()
            )
        case 3:
            return .padded(
                randomTree(depth: depth - 1, using: &generator),
                EdgeInsets(
                    top: Int.random(in: 0...10, using: &generator),
                    bottom: Int.random(in: 0...10, using: &generator),
                    leading: Int.random(in: 0...10, using: &generator),
                    trailing: Int.random(in: 0...10, using: &generator)
                )
            )
        case 4:
            return .framed(
                randomTree(depth: depth - 1, using: &generator),
                width: Bool.random(using: &generator)
                    ? Double(Int.random(in: 10...120, using: &generator)) : nil,
                height: Bool.random(using: &generator)
                    ? Double(Int.random(in: 10...120, using: &generator)) : nil,
                alignment: Alignment(
                    horizontal: horizontalAlignments.randomElement(using: &generator)!,
                    vertical: verticalAlignments.randomElement(using: &generator)!
                )
            )
        case 5:
            return .fixed(randomTree(depth: depth - 1, using: &generator))
        default:
            return randomTree(depth: 0, using: &generator)
    }
}

extension GeneratedView: View {
    var body: some View {
        switch self {
            case .leaf(let width, let height):
                AnyView(Color.blue.frame(width: width, height: height))
            case .text(let string):
                AnyView(Text(string))
            case .vStack(let alignment, let spacing, let children):
                AnyView(
                    VStack(alignment: alignment, spacing: spacing) {
                        ForEach(Array(children.enumerated()), id: \.offset) { pair in
                            pair.element
                        }
                    }
                )
            case .hStack(let alignment, let spacing, let children):
                AnyView(
                    HStack(alignment: alignment, spacing: spacing) {
                        ForEach(Array(children.enumerated()), id: \.offset) { pair in
                            pair.element
                        }
                    }
                )
            case .zStack(let alignment, let children):
                AnyView(
                    ZStack(alignment: alignment) {
                        ForEach(Array(children.enumerated()), id: \.offset) { pair in
                            pair.element
                        }
                    }
                )
            case .padded(let child, let insets):
                AnyView(child.padding(insets))
            case .framed(let child, let width, let height, let alignment):
                AnyView(child.frame(width: width, height: height, alignment: alignment))
            case .fixed(let child):
                AnyView(child.fixedSize())
        }
    }
}

extension GeometrySnapshot {
    /// A short stable fingerprint of the whole tree's geometry, so a recorded
    /// baseline stays readable.
    var digest: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in description.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
