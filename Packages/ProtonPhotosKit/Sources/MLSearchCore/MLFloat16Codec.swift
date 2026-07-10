import Foundation

/// Architecture-independent IEEE-754 binary16 codec for persisted embedding vectors.
///
/// Pure bit manipulation on purpose: no `Float16` (unavailable on Intel), no Accelerate in
/// Core (Apple-specific kernels live in the adapter). Round-to-nearest-even on encode matches
/// hardware conversion, so values written here decode to exactly what CoreML's fp16 outputs
/// would produce for the same number.
public enum MLFloat16Codec {
    /// Bytes per stored element.
    public static let bytesPerElement = 2

    /// Encode a `Float32` vector as packed little-endian binary16 — the persisted blob format.
    public static func encodeLittleEndian(_ vector: ContiguousArray<Float32>) -> Data {
        var data = Data(count: vector.count * bytesPerElement)
        data.withUnsafeMutableBytes { raw in
            var offset = 0
            for value in vector {
                let bits = float16Bits(from: value).littleEndian
                raw.storeBytes(of: bits, toByteOffset: offset, as: UInt16.self)
                offset += bytesPerElement
            }
        }
        return data
    }

    /// Decode packed little-endian binary16 bytes into a `Float32` vector, or `nil` when the
    /// byte count does not match `dimension` exactly (corrupt row).
    public static func decodeLittleEndian(_ bytes: UnsafeRawBufferPointer, dimension: Int) -> ContiguousArray<Float32>? {
        guard bytes.count == dimension * bytesPerElement else { return nil }
        var vector = ContiguousArray<Float32>()
        vector.reserveCapacity(dimension)
        for index in 0..<dimension {
            let bits = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * bytesPerElement, as: UInt16.self))
            vector.append(float32(fromBits: bits))
        }
        return vector
    }

    /// The value a `Float32` becomes after an encode/decode round trip (quantization oracle
    /// for parity tests).
    public static func quantized(_ value: Float32) -> Float32 {
        float32(fromBits: float16Bits(from: value))
    }

    /// `Float32` → binary16 bit pattern, round-to-nearest-even, overflow to ±inf, gradual
    /// underflow to subnormals, NaN preserved.
    public static func float16Bits(from value: Float32) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let magnitude = bits & 0x7fff_ffff

        if magnitude > 0x7f80_0000 {                    // NaN: keep a quiet NaN payload bit.
            return sign | 0x7e00
        }
        if magnitude >= 0x4780_0000 {                   // ≥ 65536 (incl. inf): overflows binary16.
            return sign | 0x7c00
        }

        let exponent = Int32((magnitude >> 23) & 0xff) - 127 + 15
        var mantissa = magnitude & 0x007f_ffff

        if exponent <= 0 {                              // Subnormal half (or zero).
            if exponent < -10 { return sign }           // Below smallest subnormal → ±0.
            mantissa |= 0x0080_0000                     // Make the implicit bit explicit.
            let shift = UInt32(14 - exponent)
            var half = UInt16(truncatingIfNeeded: mantissa >> shift)
            let roundBit = (mantissa >> (shift - 1)) & 1
            let sticky = (mantissa & ((1 << (shift - 1)) - 1)) != 0
            if roundBit == 1 && (sticky || (half & 1) == 1) { half &+= 1 }
            return sign | half
        }

        var half = UInt16(truncatingIfNeeded: (exponent << 10)) | UInt16(truncatingIfNeeded: mantissa >> 13)
        let roundBit = (mantissa >> 12) & 1
        let sticky = (mantissa & 0xfff) != 0
        if roundBit == 1 && (sticky || (half & 1) == 1) {
            half &+= 1                                  // Carry into the exponent is correct
        }                                               // (next binade, or 0x7c00 = inf).
        return sign | half
    }

    /// binary16 bit pattern → `Float32` (exact; every half value is representable).
    public static func float32(fromBits bits: UInt16) -> Float32 {
        let sign = UInt32(bits & 0x8000) << 16
        var exponent = Int((bits >> 10) & 0x1f)
        var significand = UInt32(bits & 0x03ff)

        let floatBits: UInt32
        if exponent == 0 {
            if significand == 0 {
                floatBits = sign
            } else {
                exponent = -14
                while significand & 0x0400 == 0 {
                    significand <<= 1
                    exponent -= 1
                }
                significand &= 0x03ff
                floatBits = sign | (UInt32(exponent + 127) << 23) | (significand << 13)
            }
        } else if exponent == 0x1f {
            floatBits = sign | 0x7f80_0000 | (significand << 13)
        } else {
            floatBits = sign | (UInt32(exponent + 112) << 23) | (significand << 13)
        }
        return Float32(bitPattern: floatBits)
    }
}
