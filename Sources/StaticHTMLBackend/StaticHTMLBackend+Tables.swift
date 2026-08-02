@_spi(Backends) import SwiftCrossUI

// Tables are where the static tier has an advantage over a native rendering
// rather than a deficit: `<table>` markup carries the row/column relationships
// in the document itself, so a screen reader can announce a cell's column
// header and a crawler can read the data as a table. A native backend draws
// those relationships and has to re-describe them through an accessibility API;
// here the structure is the output.
extension StaticHTMLBackend {
    /// A table, holding its cells in row-major order.
    public class TableWidget: Widget {
        /// The column headers, which also fix the column count.
        public var columnLabels: [String] = []
        /// Every cell, grouped by row: the first ``columnCount`` entries are
        /// row 0, and so on.
        public var cells: [Widget] = []
        /// The number of rows the table was told to hold.
        ///
        /// Tracked separately from `cells.count / columnCount` because the core
        /// sets the row count and the cells through different calls, and a
        /// render observed between the two would otherwise emit a partial row.
        public var rowCount = 0

        public var columnCount: Int {
            columnLabels.count
        }

        public override func getChildren() -> [Widget] {
            cells
        }
    }

    // MARK: - Tables

    public func createTable() -> Widget {
        TableWidget()
    }

    public func setRowCount(ofTable table: Widget, to rows: Int) {
        let table = table as! TableWidget
        table.rowCount = rows
        // The protocol requires rows outside the new bounds to be deleted. A
        // shrink that left stale cells behind would emit them into the
        // document, since emission walks `cells` rather than `rowCount`.
        let capacity = rows * table.columnCount
        if table.cells.count > capacity {
            table.cells.removeLast(table.cells.count - capacity)
        }
    }

    public func setColumnLabels(
        ofTable table: Widget,
        to labels: [String],
        environment: EnvironmentValues
    ) {
        let table = table as! TableWidget
        table.columnLabels = labels
        table.captureIntent(from: environment)
    }

    public func setCells(
        ofTable table: Widget,
        to cells: [Widget],
        withRowHeights rowHeights: [Int]
    ) {
        let table = table as! TableWidget
        table.cells = cells
        // `rowHeights` is dropped deliberately. Each height is the build host's
        // measurement of that row's tallest cell at one render width; a browser
        // re-measures the same text against a real font engine and wraps it
        // differently, so a baked per-row height would either clip content or
        // hold rows open too far. Rows sizing themselves from their content is
        // what `<table>` does natively.
    }
}
