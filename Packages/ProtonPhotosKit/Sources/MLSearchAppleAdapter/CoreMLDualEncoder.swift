import CoreGraphics
@preconcurrency import CoreML
import Foundation
import ImageIO
import MLSearchCore
import PhotosCore
import Vision

public struct CoreMLSourceImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let orientation: CGImagePropertyOrientation

    public init(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) {
        self.cgImage = cgImage
        self.orientation = orientation
    }
}

public enum CoreMLImageSourceOutcome: @unchecked Sendable {
    case image(CoreMLSourceImage)
    case permanentFailure(reason: String)
    case transientFailure
}

public protocol CoreMLImageSource: Sendable {
    func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome
}

public struct CoreMLDualEncoderSchema: Sendable, Equatable {
    public var imageFunction = "image"
    public var textFunction = "text"
    public var imageInput = "image"
    public var tokenInput = "input_ids"
    public var endTokenMaskInput = "eot_mask"
    public var embeddingOutput = "embedding"
    public var contextLength = CLIPBPETokenizer.contextLength

    public init() {}
}

public enum CoreMLDualEncoderError: Error, Equatable {
    case descriptorMismatch
    case invalidModelSchema(String)
    case invalidEmbedding
}

public actor CoreMLDualEncoder: MLAssetEmbedder, MLTextQueryEncoder {
    private let descriptor: MLModelDescriptor
    private let imageSource: any CoreMLImageSource
    private let tokenizer: any MLTextTokenizer
    private let schema: CoreMLDualEncoderSchema
    private let modelAsset: MLModelAsset
    private let computePolicy: CoreMLComputePolicy
    private let imageConstraint: MLImageConstraint
    private var activeFunction: String?
    private var activeModel: MLModel?

    public init(
        modelURL: URL,
        descriptor: MLModelDescriptor,
        imageSource: any CoreMLImageSource,
        tokenizer: any MLTextTokenizer,
        schema: CoreMLDualEncoderSchema = CoreMLDualEncoderSchema(),
        computePolicy: CoreMLComputePolicy = .default
    ) async throws {
        let modelAsset = try MLModelAsset(url: modelURL)
        async let imageDescription = modelAsset.modelDescription(of: schema.imageFunction)
        async let textDescription = modelAsset.modelDescription(of: schema.textFunction)
        let imageConstraint = try Self.validate(
            imageDescription: await imageDescription,
            textDescription: await textDescription,
            descriptor: descriptor,
            schema: schema
        )

        self.descriptor = descriptor
        self.imageSource = imageSource
        self.tokenizer = tokenizer
        self.schema = schema
        self.modelAsset = modelAsset
        self.computePolicy = computePolicy
        self.imageConstraint = imageConstraint
        self.activeFunction = nil
        self.activeModel = nil
    }

    public func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome {
        guard descriptor == self.descriptor else {
            return .permanentFailure(reason: "model descriptor mismatch")
        }

        switch await imageSource.image(for: uid) {
        case .image(let source):
            do {
                let feature = try MLFeatureValue(
                    cgImage: source.cgImage,
                    orientation: source.orientation,
                    constraint: imageConstraint,
                    options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]
                )
                let input = try MLDictionaryFeatureProvider(dictionary: [schema.imageInput: feature])
                let model = try await model(for: schema.imageFunction)
                let output = try await model.prediction(from: input)
                return .embedded(try Self.embedding(from: output, name: schema.embeddingOutput, dimension: descriptor.embeddingDimension))
            } catch {
                return .transientFailure
            }
        case .permanentFailure(let reason):
            return .permanentFailure(reason: reason)
        case .transientFailure:
            return .transientFailure
        }
    }

    public func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
        guard descriptor == self.descriptor else { throw CoreMLDualEncoderError.descriptorMismatch }
        let tokenized = try tokenizer.tokenize(text)
        guard tokenized.inputIDs.count == schema.contextLength,
              tokenized.endTokenIndex >= 0,
              tokenized.endTokenIndex < schema.contextLength else {
            throw CoreMLDualEncoderError.invalidModelSchema("tokenizer output")
        }

        let inputs = try CoreMLArrayCodec.textInputs(tokenized)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            schema.tokenInput: MLFeatureValue(multiArray: inputs.ids),
            schema.endTokenMaskInput: MLFeatureValue(multiArray: inputs.endMask),
        ])
        let model = try await model(for: schema.textFunction)
        let output = try await model.prediction(from: provider)
        return try Self.embedding(from: output, name: schema.embeddingOutput, dimension: descriptor.embeddingDimension)
    }

    public func releaseModel() {
        activeModel = nil
        activeFunction = nil
    }

    private func model(for function: String) async throws -> MLModel {
        if activeFunction == function, let activeModel { return activeModel }

        // A multi-function CLIP asset can otherwise retain both large function models. Release
        // the inactive one before loading its replacement to keep device memory bounded.
        activeModel = nil
        activeFunction = nil
        let configuration = computePolicy.modelConfiguration
        configuration.functionName = function
        let loaded = try await MLModel.load(asset: modelAsset, configuration: configuration)
        activeModel = loaded
        activeFunction = function
        return loaded
    }

    private static func validate(
        imageDescription: MLModelDescription,
        textDescription: MLModelDescription,
        descriptor: MLModelDescriptor,
        schema: CoreMLDualEncoderSchema
    ) throws -> MLImageConstraint {
        guard let imageInput = imageDescription.inputDescriptionsByName[schema.imageInput],
              imageInput.type == .image,
              let imageConstraint = imageInput.imageConstraint else {
            throw CoreMLDualEncoderError.invalidModelSchema(schema.imageInput)
        }

        guard let tokenDescription = textDescription.inputDescriptionsByName[schema.tokenInput],
              tokenDescription.type == .multiArray,
              let tokenConstraint = tokenDescription.multiArrayConstraint,
              tokenConstraint.dataType == .int32,
              tokenConstraint.shape.map(\.intValue).reduce(1, *) == schema.contextLength else {
            throw CoreMLDualEncoderError.invalidModelSchema(schema.tokenInput)
        }

        guard let maskDescription = textDescription.inputDescriptionsByName[schema.endTokenMaskInput],
              maskDescription.type == .multiArray,
              let maskConstraint = maskDescription.multiArrayConstraint,
              maskConstraint.dataType == .float32,
              maskConstraint.shape.map(\.intValue).reduce(1, *) == schema.contextLength else {
            throw CoreMLDualEncoderError.invalidModelSchema(schema.endTokenMaskInput)
        }

        try validateOutput(imageDescription, descriptor: descriptor, schema: schema)
        try validateOutput(textDescription, descriptor: descriptor, schema: schema)
        return imageConstraint
    }

    private static func validateOutput(
        _ description: MLModelDescription,
        descriptor: MLModelDescriptor,
        schema: CoreMLDualEncoderSchema
    ) throws {
        guard let output = description.outputDescriptionsByName[schema.embeddingOutput],
              output.type == .multiArray,
              let constraint = output.multiArrayConstraint,
              constraint.shape.map(\.intValue).reduce(1, *) == descriptor.embeddingDimension,
              constraint.dataType == .float16 || constraint.dataType == .float32 || constraint.dataType == .double else {
            throw CoreMLDualEncoderError.invalidModelSchema(schema.embeddingOutput)
        }
    }

    private static func embedding(
        from provider: any MLFeatureProvider,
        name: String,
        dimension: Int
    ) throws -> ContiguousArray<Float32> {
        guard let array = provider.featureValue(for: name)?.multiArrayValue,
              array.count == dimension else {
            throw CoreMLDualEncoderError.invalidEmbedding
        }
        return try CoreMLArrayCodec.float32Values(from: array)
    }
}

enum CoreMLArrayCodec {
    static func textInputs(_ text: MLTokenizedText) throws -> (ids: MLMultiArray, endMask: MLMultiArray) {
        let count = text.inputIDs.count
        let ids = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
        let endMask = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .float32)
        let idPointer = ids.dataPointer.assumingMemoryBound(to: Int32.self)
        let maskPointer = endMask.dataPointer.assumingMemoryBound(to: Float32.self)
        for index in 0..<count {
            idPointer[index] = text.inputIDs[index]
            maskPointer[index] = index == text.endTokenIndex ? 1 : 0
        }
        return (ids, endMask)
    }

    static func float32Values(from array: MLMultiArray) throws -> ContiguousArray<Float32> {
        guard isContiguous(array) else {
            return ContiguousArray((0..<array.count).map { array[$0].floatValue })
        }

        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float32.self)
            return ContiguousArray(UnsafeBufferPointer(start: pointer, count: array.count))
        case .float16:
            let pointer = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            return ContiguousArray((0..<array.count).map { float32(fromIEEE754Half: pointer[$0]) })
        case .double:
            let pointer = array.dataPointer.assumingMemoryBound(to: Double.self)
            return ContiguousArray((0..<array.count).map { Float32(pointer[$0]) })
        default:
            throw CoreMLDualEncoderError.invalidEmbedding
        }
    }

    private static func isContiguous(_ array: MLMultiArray) -> Bool {
        var expected = 1
        for index in stride(from: array.shape.count - 1, through: 0, by: -1) {
            if array.strides[index].intValue != expected { return false }
            expected *= array.shape[index].intValue
        }
        return true
    }

    static func float32(fromIEEE754Half bits: UInt16) -> Float32 {
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
