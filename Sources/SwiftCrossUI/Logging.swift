import Foundation
// On wasm, Mutex comes from WasmMutexShim.swift instead of the swift-mutex
// package, which has no wasip1 implementation.
#if !canImport(WASILibc)
    import Mutex
#endif
import Logging

private struct SourceLocation: Hashable {
    let file: String
    let line: UInt
}
private let warnedSourceLocations: Mutex<Set<SourceLocation>> = Mutex([])

extension Logger {
    func warnOnce(
        _ message: @autoclosure () -> Logger.Message,
        metadata: @autoclosure () -> Logger.Metadata? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        warnedSourceLocations.withLock { sourceLocations in
            guard sourceLocations.insert(.init(file: file, line: line)).inserted else {
                return
            }
            warning(
                message(),
                metadata: metadata(),
                file: file,
                function: function,
                line: line
            )
        }
    }
}
