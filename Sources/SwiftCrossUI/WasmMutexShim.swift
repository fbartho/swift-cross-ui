// The swift-mutex package has no wasm implementation: it selects a lock
// primitive for Darwin, Glibc/Musl/Bionic and WinSDK, and wasip1 matches none
// of them, so the module fails to compile rather than degrading gracefully.
//
// SwiftCrossUI only uses two pieces of that package's API, so on wasm it uses
// the equivalents below instead of taking the dependency at all. Keep this in
// sync with the uses in Logging.swift and State/AppStorage/AppStorage.swift; it
// is deliberately not a general-purpose replacement.

#if canImport(WASILibc)

    /// A stand-in for `Mutex` from swift-mutex on wasm.
    ///
    /// wasip1 is single-threaded and has no preemption, so there is no other
    /// context that could observe a partially-applied mutation and nothing for
    /// a lock to exclude. Holding no lock is therefore equivalent to holding
    /// one, and `withLock` reduces to calling the closure.
    ///
    /// TODO(fbartho): This assumption is specific to wasip1. The wasi-threads
    /// proposal introduces real concurrency, and building against a threaded
    /// WASI target would make this silently unsound — it would need a genuine
    /// lock at that point.
    final class Mutex<Value>: @unchecked Sendable {
        private var value: Value

        /// Creates a mutex protecting the given value.
        init(_ initialValue: Value) {
            self.value = initialValue
        }

        /// Calls `body` with mutable access to the protected value and returns
        /// its result.
        func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
            try body(&value)
        }
    }

#endif
