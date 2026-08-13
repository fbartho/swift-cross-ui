import Testing

import DummyBackend
@testable @_spi(Backends) import SwiftCrossUI

/// A guide whose default sits a fifth of the way down, far from any edge, so
/// that a container consulting it can't accidentally agree with an edge
/// alignment.
enum FifthAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.height / 5
    }
}

/// A guide combining several descendants' values by taking the smallest,
/// overriding the averaging default.
enum MinCombiningAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.height
    }

    static func combineExplicit(_ values: [Double]) -> Double {
        values.min() ?? 0
    }
}

/// A horizontal guide with a non-edge default, for the axis-independence
/// checks.
enum ThirdAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.width / 3
    }
}

extension VerticalAlignment {
    static let fifth = VerticalAlignment(FifthAlignmentID.self)
    static let minCombining = VerticalAlignment(MinCombiningAlignmentID.self)
}

extension HorizontalAlignment {
    static let third = HorizontalAlignment(ThirdAlignmentID.self)
}

@Suite("Testing alignment guides")
struct AlignmentGuideTests {
    let backend: DummyBackend
    let window: DummyBackend.Window
    let environment: EnvironmentValues

    @MainActor
    init() {
        backend = DummyBackend()
        window = backend.createWindow(withDefaultSize: nil, id: "window")
        environment = EnvironmentValues(backend: backend).with(\.window, window)
    }

    // MARK: 1. Reduction property

    /// The claim the whole design rests on: with no explicit guides and a
    /// built-in alignment, the guide-aware cross-axis algorithm produces the
    /// same sizes and offsets the three-way switch produced before it.
    ///
    /// Checked against an independent reimplementation of the old rule
    /// (``LegacyStackPlacement``) at every stack in generated trees, rather
    /// than against the layout system itself, so that the two can actually
    /// disagree.
    @MainActor
    @Test(
        "Guide-free cross-axis placement matches the pre-guides rule, over generated trees",
        arguments: 0..<60
    )
    func guideFreeReduction(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let tree = randomTree(depth: 3, using: &generator)

        let proposals: [ProposedViewSize] = [
            .unspecified,
            ProposedViewSize(200, 200),
            ProposedViewSize(80, 400),
            ProposedViewSize(400, nil),
            ProposedViewSize(nil, 150),
        ]

        for proposal in proposals {
            // The generated tree contains no alignmentGuide anywhere, so every
            // stack inside it is in the reduction case.
            let node = committedNode(for: tree, proposedSize: proposal)
            let result = node.computeLayout(
                proposedSize: proposal,
                environment: environment
            )

            // Text sources baselines intrinsically, so those are the only
            // guides a tree with no alignmentGuide in it may report.
            let unexpectedGuides = result.explicitGuides.keys.filter { key in
                key != VerticalAlignment.firstTextBaseline.key
                    && key != VerticalAlignment.lastTextBaseline.key
            }
            #expect(
                unexpectedGuides.isEmpty,
                "guide-free tree reported non-baseline guides at seed \(seed)"
            )

            for edge in [StackAlignment.leading, .center, .trailing] {
                for orientation in [Orientation.vertical, Orientation.horizontal] {
                    let childResults = childLayoutResults(
                        of: tree,
                        proposedSize: proposal
                    )
                    let comparison = LayoutSystem.compareWithLegacyPlacement(
                        of: childResults,
                        edge: edge,
                        orientation: orientation
                    )
                    #expect(
                        comparison.guideAware.crossSize == comparison.legacy.crossSize,
                        """
                        cross size diverged at seed \(seed), \(orientation): \
                        guide-aware \(comparison.guideAware.crossSize) vs \
                        legacy \(comparison.legacy.crossSize); \
                        children \(childResults.map(\.size))
                        """
                    )
                    #expect(
                        comparison.guideAware.offsets == comparison.legacy.offsets,
                        """
                        offsets diverged at seed \(seed), \(orientation): \
                        guide-aware \(comparison.guideAware.offsets) vs \
                        legacy \(comparison.legacy.offsets)
                        """
                    )
                }
            }
        }
    }

    /// The same reduction claim end-to-end, against geometry recorded from the
    /// pre-guides implementation: every position and size a guide-free tree
    /// commits must still be what it was before guides existed.
    ///
    /// Catches a divergence the algebraic check can't see, since that one
    /// compares the cross-axis rule in isolation while this compares whole
    /// committed trees through every container in the generated shapes.
    @MainActor
    @Test(
        "Guide-free trees commit the geometry the pre-guides implementation did",
        arguments: Array(preGuidesGeometry.keys).sorted()
    )
    func guideFreeCommittedGeometryMatchesBaseline(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let tree = randomTree(depth: 3, using: &generator)

        let recorded = preGuidesGeometry[seed]!
        for (index, proposal) in baselineProposals.enumerated() {
            let node = committedNode(for: tree, proposedSize: proposal)
            let geometry = geometryTree(of: node.widget)
            #expect(
                geometry.digest == recorded[index],
                "committed geometry diverged at seed \(seed), proposal \(proposal)"
            )
        }
    }

    /// Lays out a generated tree's top-level children, for feeding the
    /// cross-axis rule directly.
    @MainActor
    func childLayoutResults(
        of tree: GeneratedView,
        proposedSize: ProposedViewSize
    ) -> [ViewLayoutResult] {
        tree.generatedChildren.map { child in
            let node = ViewGraphNode(for: child, backend: backend, environment: environment)
            return node.computeLayout(proposedSize: proposedSize, environment: environment)
        }
    }

    // MARK: 2. Resolution cascade

    @MainActor
    @Test("A view's own explicit guide beats one bubbling up from its descendants")
    func ownExplicitBeatsDescendants() {
        let view = VStack(spacing: 0) {
            Color.blue.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 30 }
        }
        .alignmentGuide(.fifth) { _ in 5 }

        let result = computeLayout(of: view, proposedSize: ProposedViewSize(10, 40))
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 5)
    }

    @MainActor
    @Test("A descendant's explicit guide beats the alignment's default")
    func descendantExplicitBeatsDefault() {
        let view = VStack(spacing: 0) {
            Color.blue.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 30 }
        }

        let result = computeLayout(of: view, proposedSize: ProposedViewSize(10, 40))
        // The default would be height/5 == 8; the descendant's 30 wins.
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 30)
    }

    @MainActor
    @Test("A container ignores guides for keys it doesn't align on, but still propagates them")
    func undeclaredKeysPropagateWithoutBeingConsumed() {
        // The VStack aligns on .leading, so .fifth must not move anything…
        let view = VStack(alignment: .leading, spacing: 0) {
            Color.blue.frame(width: 20, height: 40)
                .alignmentGuide(.fifth) { _ in 30 }
            Color.green.frame(width: 60, height: 40)
        }

        let node = committedNode(for: view, proposedSize: ProposedViewSize(60, 80))
        #expect(
            positionsOfContainer(withChildCount: 2, in: node.widget)
                == [SIMD2(0, 0), SIMD2(0, 40)]
        )

        // …but an ancestor aligning on .fifth still sees it.
        let result = computeLayout(of: view, proposedSize: ProposedViewSize(60, 80))
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 30)
    }

    @MainActor
    @Test("A wrong-axis guide never reaches the other axis")
    func wrongAxisGuideIsIndependent() {
        let view = Color.blue.frame(width: 40, height: 40)
            .alignmentGuide(.third) { _ in 35 }

        let result = computeLayout(of: view, proposedSize: ProposedViewSize(40, 40))
        #expect(result.explicitGuides[HorizontalAlignment.third.key] == 35)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == nil)
    }

    // MARK: 3. Propagation transforms

    @MainActor
    @Test("Padding offsets a descendant's guide by its insets")
    func paddingTransformsGuides() {
        let view = Color.blue.frame(width: 10, height: 20)
            .alignmentGuide(.fifth) { _ in 6 }
            .padding(EdgeInsets(top: 7, bottom: 3, leading: 5, trailing: 2))

        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 13)
    }

    @MainActor
    @Test("A frame offsets a descendant's guide by where it places the child")
    func frameTransformsGuides() {
        let view = Color.blue.frame(width: 10, height: 20)
            .alignmentGuide(.fifth) { _ in 6 }
            .frame(width: 10, height: 60, alignment: .bottom)

        let result = computeLayout(of: view)
        // The child sits at y=40 inside the 60-tall frame, carrying its guide.
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 46)
    }

    @MainActor
    @Test("fixedSize passes a descendant's guide through unchanged")
    func fixedSizeTransformsGuides() {
        let view = Color.blue.frame(width: 10, height: 20)
            .alignmentGuide(.fifth) { _ in 6 }
            .fixedSize()

        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 6)
    }

    @MainActor
    @Test("An optional view passes its content's guide through unchanged")
    func optionalViewTransformsGuides() {
        let shown: Color? = Color.blue
        let view = VStack(spacing: 0) {
            if let shown {
                shown.frame(width: 10, height: 20)
                    .alignmentGuide(.fifth) { _ in 6 }
            }
        }

        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 6)
    }

    @MainActor
    @Test("A guide survives a chain of mixed transforms, accumulating each offset")
    func mixedTransformChain() {
        let view = Color.blue.frame(width: 10, height: 20)
            .alignmentGuide(.fifth) { _ in 6 }
            .padding(EdgeInsets(top: 4, bottom: 0, leading: 0, trailing: 0))
            .fixedSize()
            .frame(width: 10, height: 80, alignment: .bottom)
            .padding(EdgeInsets(top: 2, bottom: 0, leading: 0, trailing: 0))

        // 6 + 4 (padding) then placed at y=56 in the 80-tall frame, then +2.
        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 68)
    }

    // MARK: 4. Merging

    @MainActor
    @Test("Explicit values from several branches average by default")
    func mergingAverages() {
        let view = VStack(alignment: .leading, spacing: 0) {
            Color.blue.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 10 }
            Color.green.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 20 }
        }

        let result = computeLayout(of: view, proposedSize: ProposedViewSize(10, 80))
        // Second child sits at y=40, so its guide reads 60 here; (10+60)/2.
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 35)
    }

    @MainActor
    @Test("A custom combineExplicit overrides the averaging default")
    func mergingUsesCustomCombiner() {
        let view = VStack(alignment: .leading, spacing: 0) {
            Color.blue.frame(width: 10, height: 40)
                .alignmentGuide(.minCombining) { _ in 10 }
            Color.green.frame(width: 10, height: 40)
                .alignmentGuide(.minCombining) { _ in 20 }
        }

        let result = computeLayout(of: view, proposedSize: ProposedViewSize(10, 80))
        // Values are 10 and 60 in the stack's space; min wins over the mean.
        #expect(result.explicitGuides[VerticalAlignment.minCombining.key] == 10)
    }

    // MARK: 5. Sizing (behaviour 5)

    @MainActor
    @Test("A stack's cross size is the largest extent above its guide line plus the largest below")
    func crossSizeIsAboveePlusBelow() {
        let view = HStack(alignment: .fifth, spacing: 0) {
            Color.blue.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 30 }
            Color.green.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 10 }
        }

        let result = computeLayout(of: view, proposedSize: ProposedViewSize(20, nil))
        // Line at max(30, 10) = 30; below is max(40-30, 40-10) = 30.
        #expect(result.size.height == 60)
    }

    @MainActor
    @Test("A guide-shifted child grows its container past its tallest child")
    func guideGrowsContainerPastTallestChild() {
        let view = HStack(alignment: .fifth, spacing: 0) {
            Color.blue.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 0 }
            Color.green.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 40 }
        }

        let result = computeLayout(of: view, proposedSize: ProposedViewSize(20, nil))
        // Line at 40, below is max(40-0, 40-40) = 40, so 80 — twice the
        // tallest child, which a max-of-sizes rule could never produce.
        #expect(result.size.height == 80)
    }

    @MainActor
    @Test("Guide values outside the view's own box are legal and grow the container")
    func outOfRangeGuidesAreLegal() {
        let negative = HStack(alignment: .fifth, spacing: 0) {
            Color.blue.frame(width: 10, height: 20)
                .alignmentGuide(.fifth) { _ in -10 }
            Color.green.frame(width: 10, height: 20)
                .alignmentGuide(.fifth) { _ in 10 }
        }

        let result = computeLayout(of: negative, proposedSize: ProposedViewSize(20, nil))
        // Line at 10; below is max(20-(-10), 20-10) = 30, so 40.
        #expect(result.size.height == 40)

        let beyond = HStack(alignment: .fifth, spacing: 0) {
            Color.blue.frame(width: 10, height: 20)
                .alignmentGuide(.fifth) { _ in 50 }
            Color.green.frame(width: 10, height: 20)
                .alignmentGuide(.fifth) { _ in 0 }
        }

        let beyondResult = computeLayout(of: beyond, proposedSize: ProposedViewSize(20, nil))
        // Line at 50; below is max(20-50, 20-0) = 20, so 70.
        #expect(beyondResult.size.height == 70)
    }

    @MainActor
    @Test("Children are shifted so their guide lines coincide")
    func childrenShiftToShareOneLine() {
        let view = HStack(alignment: .fifth, spacing: 0) {
            Color.blue.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 30 }
            Color.green.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 10 }
        }

        let node = committedNode(for: view, proposedSize: ProposedViewSize(20, nil))
        // Line at 30: the first child needs no shift, the second drops 20 so
        // its own guide reaches the same line.
        #expect(positionsOfContainer(withChildCount: 2, in: node.widget) == [
            SIMD2(0, 0),
            SIMD2(10, 20)
        ])
    }

    @MainActor
    @Test("Nested containers aligning on different keys each resolve their own")
    func nestedContainersOnDifferentKeys() {
        let inner = HStack(alignment: .fifth, spacing: 0) {
            Color.blue.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 30 }
            Color.green.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { _ in 10 }
        }
        let view = VStack(alignment: .third, spacing: 0) {
            inner
            Color.red.frame(width: 40, height: 10)
                .alignmentGuide(.third) { _ in 0 }
        }

        let result = computeLayout(of: view, proposedSize: ProposedViewSize(nil, nil))
        // The inner stack's own .fifth sizing still holds inside the outer one.
        #expect(result.size.height == 70)
    }

    // MARK: 6. Phase staleness

    /// The redistribution path re-runs layout at commit and children's sizes
    /// genuinely change. Positions must match a from-scratch layout at the
    /// final size, not the pre-redistribution guesses.
    @MainActor
    @Test("Committed positions survive commit-time space redistribution")
    func redistributionDoesNotStaleGuides() {
        // A nil cross proposal is what triggers redistribution on commit.
        let view = VStack(alignment: .leading, spacing: 0) {
            Text("Dummy")
            Color.blue
            Text("Dummy")
        }.fixedSize()

        let node = committedNode(for: view, proposedSize: ProposedViewSize(200, 200))
        let stack = node.widget.getChildren()[0]

        // Positions must be exactly the running sum of the committed sizes —
        // which is only true if commit re-derived them from post-
        // redistribution sizes.
        var expectedY = 0
        for child in stack.getChildren() {
            #expect(positionOfChild(child, in: stack)?.y == expectedY)
            expectedY += child.size.y
        }
    }

    @MainActor
    @Test("A guide resolved at commit uses the child's post-redistribution size")
    func redistributionRederivesGuides() {
        let view = HStack(alignment: .fifth, spacing: 0) {
            Color.blue.frame(width: 10, height: 40)
                .alignmentGuide(.fifth) { dimensions in dimensions.height / 2 }
            Color.green.frame(width: 10, height: 20)
                .alignmentGuide(.fifth) { dimensions in dimensions.height / 2 }
        }

        let node = committedNode(for: view, proposedSize: ProposedViewSize(20, nil))
        // Lines at 20 and 10 respectively, so the shorter child drops by 10.
        #expect(positionsOfContainer(withChildCount: 2, in: node.widget) == [
            SIMD2(0, 0),
            SIMD2(10, 10)
        ])
    }

    // MARK: 7. ViewDimensions composability

    @MainActor
    @Test("A guide can be defined in terms of the view's size")
    func guideReadsOwnSize() {
        let view = Color.blue.frame(width: 30, height: 60)
            .alignmentGuide(.fifth) { dimensions in dimensions.height / 4 }

        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 15)
    }

    @MainActor
    @Test("A guide can be defined in terms of another guide's resolved value")
    func guideReadsAnotherGuide() {
        let view = Color.blue.frame(width: 30, height: 60)
            .alignmentGuide(.fifth) { dimensions in dimensions[.bottom] - 10 }

        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 50)
    }

    @MainActor
    @Test("A guide reading another explicit guide sees the explicit value, not the default")
    func guideReadsAnotherExplicitGuide() {
        let view = Color.blue.frame(width: 30, height: 60)
            .alignmentGuide(VerticalAlignment.center) { _ in 12 }
            .alignmentGuide(.fifth) { dimensions in
                dimensions[VerticalAlignment.center] * 2
            }

        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 24)
        // The explicit subscript reports only what was actually set.
        #expect(result.dimensions[explicit: VerticalAlignment.center] == 12)
        #expect(result.dimensions[explicit: VerticalAlignment.bottom] == nil)
    }

    @MainActor
    @Test("An unset guide resolves to its alignment's default")
    func unsetGuideResolvesToDefault() {
        let dimensions = ViewDimensions(size: ViewSize(30, 60), explicitGuides: [:])
        #expect(dimensions[HorizontalAlignment.leading] == 0)
        #expect(dimensions[HorizontalAlignment.center] == 15)
        #expect(dimensions[HorizontalAlignment.trailing] == 30)
        #expect(dimensions[VerticalAlignment.top] == 0)
        #expect(dimensions[VerticalAlignment.center] == 30)
        #expect(dimensions[VerticalAlignment.bottom] == 60)
        #expect(dimensions[VerticalAlignment.fifth] == 12)
    }

    // MARK: 8. ZStack, overlay and frame

    @MainActor
    @Test("A ZStack resolves guides on both axes at once")
    func zStackAlignsBothAxes() {
        let view = ZStack(alignment: Alignment(horizontal: .third, vertical: .fifth)) {
            Color.blue.frame(width: 40, height: 40)
                .alignmentGuide(.third) { _ in 30 }
                .alignmentGuide(.fifth) { _ in 30 }
            Color.green.frame(width: 40, height: 40)
                .alignmentGuide(.third) { _ in 10 }
                .alignmentGuide(.fifth) { _ in 10 }
        }

        let node = committedNode(for: view)
        #expect(positionsOfContainer(withChildCount: 2, in: node.widget) == [
            SIMD2(0, 0),
            SIMD2(20, 20)
        ])

        let result = computeLayout(of: view)
        // Both axes: line at 30, beyond is max(40-30, 40-10) = 30.
        #expect(result.size == ViewSize(60, 60))
    }

    @MainActor
    @Test("An overlay propagates only the base's guides, never the decoration's")
    func overlayPropagatesBaseGuidesOnly() {
        let view = Color.blue.frame(width: 40, height: 40)
            .alignmentGuide(.fifth) { _ in 30 }
            .overlay {
                Color.green.frame(width: 10, height: 10)
                    .alignmentGuide(.fifth) { _ in 0 }
            }

        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 30)
    }

    @MainActor
    @Test("A background propagates only the foreground's guides")
    func backgroundPropagatesForegroundGuidesOnly() {
        let view = Color.blue.frame(width: 40, height: 40)
            .alignmentGuide(.fifth) { _ in 30 }
            .background {
                Color.green.frame(width: 40, height: 40)
                    .alignmentGuide(.fifth) { _ in 0 }
            }

        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.fifth.key] == 30)
    }

    @MainActor
    @Test("A frame places its child by the child's explicit guide")
    func frameConsumesGuides() {
        let view = Color.blue.frame(width: 10, height: 20)
            .alignmentGuide(.top) { _ in -10 }
            .frame(width: 10, height: 60, alignment: .top)

        // The child's .top guide sits 10 above its own box, so aligning that
        // guide to the frame's top edge pushes the child down by 10.
        let node = committedNode(for: view)
        #expect(committedOffsets(in: node.widget).contains(SIMD2(0, 10)))

        // The frame reports the child's guide shifted by where it placed it.
        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.top.key] == 0)
    }

    @MainActor
    @Test("The flexible frame variant also places its child by explicit guides")
    func flexibleFrameConsumesGuides() {
        let view = Color.blue.frame(width: 10, height: 20)
            .alignmentGuide(.top) { _ in -10 }
            .frame(minHeight: 60, alignment: .top)

        let node = committedNode(for: view)
        #expect(committedOffsets(in: node.widget).contains(SIMD2(0, 10)))

        let result = computeLayout(of: view)
        #expect(result.explicitGuides[VerticalAlignment.top.key] == 0)
    }

    // MARK: Multi-child guide consumers

    /// The container side of an alignment used to resolve against the
    /// container's own default for the guide, which is a value none of its
    /// children reported. With two children both sourcing a custom guide, that
    /// puts the one whose guide sits deepest in its own box at a negative
    /// offset, outside the container.
    @MainActor
    @Test("An overlay aligning a custom guide keeps both children inside itself")
    func overlayOnCustomGuideKeepsChildrenInside() {
        let view = Color.blue.frame(width: 40, height: 40)
            .alignmentGuide(.fifth) { _ in 35 }
            .overlay(alignment: Alignment(horizontal: .center, vertical: .fifth)) {
                Color.green.frame(width: 10, height: 10)
                    .alignmentGuide(.fifth) { _ in 5 }
            }

        let node = committedNode(for: view)
        let offsets = committedOffsets(in: node.widget)
        #expect(
            offsets.allSatisfy { $0.y >= 0 },
            "a child was placed above the overlay's own top edge: \(offsets)"
        )
    }

    /// Both children of a multi-child consumer land on one line, rather than
    /// each being resolved against the container independently.
    @MainActor
    @Test("An overlay places both children on one shared custom-guide line")
    func overlayPlacesBothChildrenOnOneLine() {
        let view = Color.blue.frame(width: 40, height: 40)
            .alignmentGuide(.fifth) { _ in 30 }
            .overlay(alignment: Alignment(horizontal: .center, vertical: .fifth)) {
                Color.green.frame(width: 10, height: 10)
                    .alignmentGuide(.fifth) { _ in 4 }
            }

        let node = committedNode(for: view)
        let container = container(withChildCount: 2, in: node.widget)
        let positions = positions(of: container ?? node.widget)

        // The line sits at 30, so the base needs no shift and the overlay drops
        // to 26 to put its own guide on the same line.
        #expect(positions.map(\.y) == [0, 26])
    }

    /// A single-child consumer is the case the old container-side resolution
    /// got right, so the fix must leave it exactly where it was.
    @MainActor
    @Test("A frame still places a single guide-setting child where it always did")
    func singleChildFramePlacementIsUnchanged() {
        for alignment in [Alignment.top, .center, .bottom] {
            let view = Color.blue.frame(width: 10, height: 20)
                .alignmentGuide(.fifth) { _ in 6 }
                .frame(width: 10, height: 60, alignment: alignment)

            let result = computeLayout(of: view)
            // The child's guide is the line whatever the frame aligns on, so
            // the frame reports it offset by wherever the child was placed.
            let placed = alignment.vertical.position(ofChild: 20, in: 60)
            #expect(result.explicitGuides[VerticalAlignment.fifth.key] == placed + 6)
        }
    }

    // MARK: Helpers

    @MainActor
    func computeLayout<V: View>(
        of view: V,
        proposedSize: ProposedViewSize = .unspecified
    ) -> ViewLayoutResult {
        let node = ViewGraphNode(for: view, backend: backend, environment: environment)
        return node.computeLayout(proposedSize: proposedSize, environment: environment)
    }

    @MainActor
    func committedNode<V: View>(
        for view: V,
        proposedSize: ProposedViewSize = .unspecified
    ) -> ViewGraphNode<V, DummyBackend> {
        let node = ViewGraphNode(for: view, backend: backend, environment: environment)
        _ = node.computeLayout(proposedSize: proposedSize, environment: environment)
        _ = node.commit()
        return node
    }

    /// The positions a container assigned to its children, in child order.
    @MainActor
    func positions(of container: DummyBackend.Widget) -> [SIMD2<Int>] {
        (container as? DummyBackend.Container)?.children.map(\.position) ?? []
    }

    /// The positions of the children of the first container in the tree that
    /// holds `count` of them.
    ///
    /// View trees wrap containers in containers, at a depth that depends on
    /// which modifiers are in play, so tests name the container they mean by
    /// its child count rather than by a path that shifts under them.
    @MainActor
    func positionsOfContainer(
        withChildCount count: Int,
        in root: DummyBackend.Widget
    ) -> [SIMD2<Int>] {
        positions(of: container(withChildCount: count, in: root) ?? root)
    }

    /// Every position any container in the tree assigned to a child.
    ///
    /// Lets a test name the offset it expects without naming the path to the
    /// container that produced it, which shifts as modifiers wrap widgets.
    @MainActor
    func committedOffsets(in root: DummyBackend.Widget) -> [SIMD2<Int>] {
        var offsets: [SIMD2<Int>] = []
        var queue = [root]
        while let widget = queue.first {
            queue.removeFirst()
            if let container = widget as? DummyBackend.Container {
                offsets.append(contentsOf: container.children.map(\.position))
            }
            queue.append(contentsOf: widget.getChildren())
        }
        return offsets
    }

    /// The first container in the tree holding exactly `count` children,
    /// breadth-first from `root`.
    @MainActor
    func container(
        withChildCount count: Int,
        in root: DummyBackend.Widget
    ) -> DummyBackend.Widget? {
        var queue = [root]
        while let widget = queue.first {
            queue.removeFirst()
            if let container = widget as? DummyBackend.Container,
               container.children.count == count
            {
                return container
            }
            queue.append(contentsOf: widget.getChildren())
        }
        return nil
    }

    @MainActor
    func positionOfChild(
        _ child: DummyBackend.Widget,
        in container: DummyBackend.Widget
    ) -> SIMD2<Int>? {
        (container as? DummyBackend.Container)?
            .children
            .first { $0.widget === child }?
            .position
    }
}
