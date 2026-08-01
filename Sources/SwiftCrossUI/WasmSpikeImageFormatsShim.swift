// SPIKE-ONLY SHIM — not for upstream.
//
// Stands in for the `ImageFormats` product while probing whether the rest of
// SwiftCrossUI's core compiles for wasm32-unknown-wasip1. The real ImageFormats
// depends on libpng/libwebp/jpeg, whose C sources need setjmp/longjmp — an
// unsupported wasm feature without the Exception Handling proposal.
//
// This reproduces only the API surface Views/Image.swift touches.

#if canImport(WASILibc)

public struct RGBA: Equatable, Sendable {
	var red: UInt8
	var green: UInt8
	var blue: UInt8
	var alpha: UInt8
}

/// Foundation's `Progress` is absent from the wasm SDK's Foundation.
/// Only the surface ProgressView.swift touches is reproduced here.
public final class Progress: @unchecked Sendable {
	public var totalUnitCount: Int64 = 0
	public var completedUnitCount: Int64 = 0
	public var isIndeterminate: Bool { totalUnitCount == 0 }
	public var fractionCompleted: Double {
		totalUnitCount == 0 ? 0 : Double(completedUnitCount) / Double(totalUnitCount)
	}
}

public enum ImageFormats {
	public struct Image<Component>: Equatable, Sendable {
		public var width: Int
		public var height: Int
		public var bytes: [UInt8] = []

		public static func load(from bytes: [UInt8]) throws -> Image<Component> {
			throw ImageFormatsShimError.unsupportedOnWasmSpike
		}

		public static func load(
			from bytes: [UInt8],
			usingFileExtension fileExtension: String
		) throws -> Image<Component> {
			throw ImageFormatsShimError.unsupportedOnWasmSpike
		}
	}
}

enum ImageFormatsShimError: Error {
	case unsupportedOnWasmSpike
}

#endif
