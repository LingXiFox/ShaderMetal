#include "render/ShaderRegistry.hpp"

#include "core/ShaderCompiler.hpp"

#include <array>
#include <limits>
#include <new>
#include <sstream>
#include <utility>

namespace shadermetal {
namespace {

constexpr NSUInteger kVertexBufferIndex = 30;

const char *phaseName(ShaderDiagnosticPhase phase) {
    switch (phase) {
    case ShaderDiagnosticPhase::InputValidation:
        return "input";
    case ShaderDiagnosticPhase::Initialization:
        return "initialization";
    case ShaderDiagnosticPhase::Parsing:
        return "parsing";
    case ShaderDiagnosticPhase::Linking:
        return "linking";
    case ShaderDiagnosticPhase::SpirvGeneration:
        return "SPIR-V";
    case ShaderDiagnosticPhase::MslGeneration:
        return "MSL";
    }
    return "unknown";
}

std::string describeCompilationFailure(const ShaderCompilationResult &result,
                                       std::string_view stageName) {
    std::ostringstream stream;
    stream << stageName << " shader compilation failed";
    for (const ShaderDiagnostic &diagnostic : result.diagnostics) {
        stream << "\n[" << phaseName(diagnostic.phase) << "] " << diagnostic.message;
    }
    return stream.str();
}

std::string metalErrorMessage(NSError *error, std::string_view fallback) {
    if (error != nil && error.localizedDescription != nil) {
        return std::string(error.localizedDescription.UTF8String);
    }
    return std::string(fallback);
}

bool createMetalStage(id<MTLDevice> device, const std::string &msl,
                      id<MTLLibrary> __strong &library,
                      id<MTLFunction> __strong &function,
                      std::string &error) {
    NSString *source = [[NSString alloc] initWithBytes:msl.data()
                                               length:msl.size()
                                             encoding:NSUTF8StringEncoding];
    if (source == nil) {
        error = "generated MSL is not valid UTF-8";
        return false;
    }

    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
    options.languageVersion = MTLLanguageVersion3_0;

    NSError *libraryError = nil;
    library = [device newLibraryWithSource:source options:options error:&libraryError];
    if (library == nil) {
        error = metalErrorMessage(libraryError, "Metal failed to compile generated MSL");
        return false;
    }

    function = [library newFunctionWithName:@"main0"];
    if (function == nil) {
        error = "generated Metal library has no translated main0 entry point";
        return false;
    }
    return true;
}

void setAttribute(MTLVertexDescriptor *descriptor, NSUInteger index,
                  MTLVertexFormat format, NSUInteger offset) {
    MTLVertexAttributeDescriptor *attribute = descriptor.attributes[index];
    attribute.format = format;
    attribute.offset = offset;
    attribute.bufferIndex = kVertexBufferIndex;
}

MTLVertexDescriptor *vertexDescriptorForType(std::int32_t type,
                                             std::size_t &stride,
                                             std::string &error) {
    MTLVertexDescriptor *descriptor = [MTLVertexDescriptor vertexDescriptor];
    NSUInteger attribute = 0;
    const auto add = [&](MTLVertexFormat format, NSUInteger offset) {
        setAttribute(descriptor, attribute++, format, offset);
    };

    switch (type) {
    case 0: // POSITION_COLOR_TEXTURE_LIGHT_NORMAL
        stride = 32;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatUChar4Normalized, 12);
        add(MTLVertexFormatFloat2, 16);
        add(MTLVertexFormatShort2, 24);
        add(MTLVertexFormatChar3Normalized, 28);
        break;
    case 1: // POSITION_COLOR_TEXTURE_OVERLAY_LIGHT_NORMAL
        stride = 36;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatUChar4Normalized, 12);
        add(MTLVertexFormatFloat2, 16);
        add(MTLVertexFormatShort2, 24);
        add(MTLVertexFormatShort2, 28);
        add(MTLVertexFormatChar3Normalized, 32);
        break;
    case 2: // POSITION_TEXTURE_COLOR_LIGHT
        stride = 28;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatFloat2, 12);
        add(MTLVertexFormatUChar4Normalized, 20);
        add(MTLVertexFormatShort2, 24);
        break;
    case 3: // POSITION
        stride = 12;
        add(MTLVertexFormatFloat3, 0);
        break;
    case 4: // POSITION_COLOR
        stride = 16;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatUChar4Normalized, 12);
        break;
    case 5: // LINES
        stride = 20;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatUChar4Normalized, 12);
        add(MTLVertexFormatChar3Normalized, 16);
        break;
    case 6: // POSITION_COLOR_LIGHT
        stride = 20;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatUChar4Normalized, 12);
        add(MTLVertexFormatShort2, 16);
        break;
    case 7: // POSITION_TEXTURE
        stride = 20;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatFloat2, 12);
        break;
    case 8: // POSITION_TEXTURE_COLOR
        stride = 24;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatFloat2, 12);
        add(MTLVertexFormatUChar4Normalized, 20);
        break;
    case 9: // POSITION_COLOR_TEXTURE_LIGHT
        stride = 28;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatUChar4Normalized, 12);
        add(MTLVertexFormatFloat2, 16);
        add(MTLVertexFormatShort2, 24);
        break;
    case 10: // POSITION_TEXTURE_LIGHT_COLOR
        stride = 28;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatFloat2, 12);
        add(MTLVertexFormatShort2, 20);
        add(MTLVertexFormatUChar4Normalized, 24);
        break;
    case 11: // POSITION_TEXTURE_COLOR_NORMAL
        stride = 28;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatFloat2, 12);
        add(MTLVertexFormatUChar4Normalized, 20);
        add(MTLVertexFormatChar3Normalized, 24);
        break;
    case 12: // Radiance-compatible PBR_TRIANGLE contract
        stride = 128;
        add(MTLVertexFormatFloat3, 0);
        add(MTLVertexFormatUInt, 12);
        add(MTLVertexFormatFloat3, 16);
        add(MTLVertexFormatUInt, 28);
        add(MTLVertexFormatFloat4, 32);
        add(MTLVertexFormatUInt, 48);
        add(MTLVertexFormatUInt, 52);
        add(MTLVertexFormatFloat2, 56);
        add(MTLVertexFormatInt2, 64);
        add(MTLVertexFormatUInt, 72);
        add(MTLVertexFormatUInt, 76);
        add(MTLVertexFormatFloat2, 80);
        add(MTLVertexFormatUInt, 88);
        add(MTLVertexFormatUInt, 92);
        add(MTLVertexFormatInt2, 96);
        add(MTLVertexFormatUInt, 104);
        add(MTLVertexFormatUInt, 108);
        add(MTLVertexFormatFloat3, 112);
        break;
    default:
        error = "unsupported Minecraft vertex format type " + std::to_string(type);
        return nil;
    }

    MTLVertexBufferLayoutDescriptor *layout = descriptor.layouts[kVertexBufferIndex];
    layout.stride = stride;
    layout.stepFunction = MTLVertexStepFunctionPerVertex;
    layout.stepRate = 1;
    return descriptor;
}

bool primitiveTopologyForDrawMode(std::int32_t drawMode,
                                  MTLPrimitiveTopologyClass &topology,
                                  std::string &error) {
    switch (drawMode) {
    case 0: // LINES
    case 1: // LINE_STRIP
    case 2: // DEBUG_LINES
    case 3: // DEBUG_LINE_STRIP
        topology = MTLPrimitiveTopologyClassLine;
        return true;
    case 4: // TRIANGLES
    case 5: // TRIANGLE_STRIP
    case 7: // QUADS, converted to indexed triangles by BufferProxy
        topology = MTLPrimitiveTopologyClassTriangle;
        return true;
    case 6:
        error = "triangle-fan draw mode requires index conversion before Metal encoding";
        return false;
    default:
        error = "unsupported draw mode " + std::to_string(drawMode);
        return false;
    }
}

bool metalBlendFactor(std::int32_t value, MTLBlendFactor &factor) {
    switch (value) {
    case 0: factor = MTLBlendFactorZero; return true;
    case 1: factor = MTLBlendFactorOne; return true;
    case 2: factor = MTLBlendFactorSourceColor; return true;
    case 3: factor = MTLBlendFactorOneMinusSourceColor; return true;
    case 4: factor = MTLBlendFactorDestinationColor; return true;
    case 5: factor = MTLBlendFactorOneMinusDestinationColor; return true;
    case 6: factor = MTLBlendFactorSourceAlpha; return true;
    case 7: factor = MTLBlendFactorOneMinusSourceAlpha; return true;
    case 8: factor = MTLBlendFactorDestinationAlpha; return true;
    case 9: factor = MTLBlendFactorOneMinusDestinationAlpha; return true;
    case 10: factor = MTLBlendFactorBlendColor; return true;
    case 11: factor = MTLBlendFactorOneMinusBlendColor; return true;
    case 12: factor = MTLBlendFactorBlendAlpha; return true;
    case 13: factor = MTLBlendFactorOneMinusBlendAlpha; return true;
    case 14: factor = MTLBlendFactorSourceAlphaSaturated; return true;
    case 15: factor = MTLBlendFactorSource1Color; return true;
    case 16: factor = MTLBlendFactorOneMinusSource1Color; return true;
    case 17: factor = MTLBlendFactorSource1Alpha; return true;
    case 18: factor = MTLBlendFactorOneMinusSource1Alpha; return true;
    default: return false;
    }
}

bool metalBlendOperation(std::int32_t value, MTLBlendOperation &operation) {
    switch (value) {
    case 0: operation = MTLBlendOperationAdd; return true;
    case 1: operation = MTLBlendOperationSubtract; return true;
    case 2: operation = MTLBlendOperationReverseSubtract; return true;
    case 3: operation = MTLBlendOperationMin; return true;
    case 4: operation = MTLBlendOperationMax; return true;
    default: return false;
    }
}

MTLColorWriteMask metalColorWriteMask(std::uint32_t mask) {
    MTLColorWriteMask result = MTLColorWriteMaskNone;
    if ((mask & 0x1U) != 0) result |= MTLColorWriteMaskRed;
    if ((mask & 0x2U) != 0) result |= MTLColorWriteMaskGreen;
    if ((mask & 0x4U) != 0) result |= MTLColorWriteMaskBlue;
    if ((mask & 0x8U) != 0) result |= MTLColorWriteMaskAlpha;
    return result;
}

} // namespace

ShaderRegistry &ShaderRegistry::shared() {
    static ShaderRegistry registry;
    return registry;
}

ShaderRegistry::ShaderId ShaderRegistry::registerShader(
    std::string_view key, std::int32_t vertexFormatType, std::int32_t drawMode,
    std::int32_t uniformSize, std::string_view vertexSource,
    std::string_view fragmentSource, id<MTLDevice> device, std::string &error) {
    error.clear();
    if (device == nil) {
        error = "cannot register a shader without a Metal device";
        return kInvalidShaderId;
    }
    if (key.empty()) {
        error = "shader key is empty";
        return kInvalidShaderId;
    }
    if (uniformSize < 0) {
        error = "shader uniform size is negative";
        return kInvalidShaderId;
    }

    std::size_t vertexStride = 0;
    MTLVertexDescriptor *vertexDescriptor =
        vertexDescriptorForType(vertexFormatType, vertexStride, error);
    if (vertexDescriptor == nil) {
        return kInvalidShaderId;
    }

    MTLPrimitiveTopologyClass topology = MTLPrimitiveTopologyClassUnspecified;
    if (!primitiveTopologyForDrawMode(drawMode, topology, error)) {
        return kInvalidShaderId;
    }
    (void)topology;

    const std::string vertexName = std::string(key) + ".vert";
    const ShaderCompilationResult vertexResult = ShaderCompiler::glslToMsl(
        ShaderStage::Vertex, vertexSource, vertexName);
    if (!vertexResult.success) {
        error = describeCompilationFailure(vertexResult, "vertex");
        return kInvalidShaderId;
    }

    const std::string fragmentName = std::string(key) + ".frag";
    const ShaderCompilationResult fragmentResult = ShaderCompiler::glslToMsl(
        ShaderStage::Fragment, fragmentSource, fragmentName);
    if (!fragmentResult.success) {
        error = describeCompilationFailure(fragmentResult, "fragment");
        return kInvalidShaderId;
    }

    id<MTLLibrary> vertexLibrary = nil;
    id<MTLFunction> vertexFunction = nil;
    if (!createMetalStage(device, vertexResult.msl, vertexLibrary, vertexFunction, error)) {
        error = "vertex Metal compilation failed: " + error;
        return kInvalidShaderId;
    }

    id<MTLLibrary> fragmentLibrary = nil;
    id<MTLFunction> fragmentFunction = nil;
    if (!createMetalStage(device, fragmentResult.msl, fragmentLibrary,
                          fragmentFunction, error)) {
        error = "fragment Metal compilation failed: " + error;
        return kInvalidShaderId;
    }

    ShaderRecord record;
    record.key = std::string(key);
    record.vertexFormatType = vertexFormatType;
    record.drawMode = drawMode;
    record.vertexStride = vertexStride;
    record.uniformSize = static_cast<std::size_t>(uniformSize);
    record.vertexUsesArgumentBuffer =
        vertexResult.msl.find("[[id(") != std::string::npos ||
        vertexResult.msl.find("spvDescriptorSetBuffer0") != std::string::npos;
    record.fragmentUsesArgumentBuffer =
        fragmentResult.msl.find("[[id(") != std::string::npos ||
        fragmentResult.msl.find("spvDescriptorSetBuffer0") != std::string::npos;
    record.usesArgumentBuffers = record.vertexUsesArgumentBuffer ||
        record.fragmentUsesArgumentBuffer;
    record.vertexLibrary = vertexLibrary;
    record.fragmentLibrary = fragmentLibrary;
    record.vertexFunction = vertexFunction;
    record.fragmentFunction = fragmentFunction;
    record.vertexDescriptor = vertexDescriptor;

    std::lock_guard lock(mutex_);
    if (nextId_ > std::numeric_limits<ShaderId>::max()) {
        error = "shader ID space is exhausted";
        return kInvalidShaderId;
    }
    record.shaderId = static_cast<ShaderId>(nextId_++);
    try {
        shaders_.emplace(record.shaderId, record);
    } catch (const std::bad_alloc &) {
        error = "unable to retain registered shader";
        return kInvalidShaderId;
    }
    return record.shaderId;
}

std::optional<ShaderRecord> ShaderRegistry::shader(ShaderId id) const {
    std::lock_guard lock(mutex_);
    const auto iterator = shaders_.find(id);
    if (iterator == shaders_.end()) {
        return std::nullopt;
    }
    return iterator->second;
}

id<MTLRenderPipelineState> ShaderRegistry::createRenderPipelineState(
    ShaderId shaderId, const PipelineKey &state, id<MTLDevice> device,
    std::string &error) const {
    error.clear();
    if (device == nil) {
        error = "cannot create a render pipeline without a Metal device";
        return nil;
    }

    const std::optional<ShaderRecord> record = shader(shaderId);
    if (!record.has_value()) {
        error = "shader ID is not registered";
        return nil;
    }
    if (record->vertexFunction == nil || record->fragmentFunction == nil ||
        record->vertexDescriptor == nil) {
        error = "registered shader is missing a Metal function or vertex descriptor";
        return nil;
    }
    if (state.colorLogicOperationEnabled && state.colorLogicOperation != 3) {
        error = "Metal has no fixed-function color logic operation; only COPY is equivalent";
        return nil;
    }

    MTLPrimitiveTopologyClass topology = MTLPrimitiveTopologyClassUnspecified;
    if (!primitiveTopologyForDrawMode(record->drawMode, topology, error)) {
        return nil;
    }

    MTLRenderPipelineDescriptor *descriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.label = [NSString stringWithFormat:@"ShaderMetal Pipeline %d", shaderId];
    descriptor.vertexFunction = record->vertexFunction;
    descriptor.fragmentFunction = record->fragmentFunction;
    descriptor.vertexDescriptor = record->vertexDescriptor;
    descriptor.inputPrimitiveTopology = topology;
    descriptor.rasterSampleCount = 1;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    descriptor.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

    MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    color.writeMask = metalColorWriteMask(state.colorWriteMask);
    color.blendingEnabled = state.blendEnabled && !state.colorLogicOperationEnabled;
    if (color.blendingEnabled) {
        MTLBlendFactor sourceColor = MTLBlendFactorOne;
        MTLBlendFactor sourceAlpha = MTLBlendFactorOne;
        MTLBlendFactor destinationColor = MTLBlendFactorZero;
        MTLBlendFactor destinationAlpha = MTLBlendFactorZero;
        MTLBlendOperation colorOperation = MTLBlendOperationAdd;
        MTLBlendOperation alphaOperation = MTLBlendOperationAdd;
        if (!metalBlendFactor(state.sourceColorBlendFactor, sourceColor) ||
            !metalBlendFactor(state.sourceAlphaBlendFactor, sourceAlpha) ||
            !metalBlendFactor(state.destinationColorBlendFactor, destinationColor) ||
            !metalBlendFactor(state.destinationAlphaBlendFactor, destinationAlpha) ||
            !metalBlendOperation(state.colorBlendOperation, colorOperation) ||
            !metalBlendOperation(state.alphaBlendOperation, alphaOperation)) {
            error = "render state contains an unsupported Vulkan blend enum";
            return nil;
        }
        color.sourceRGBBlendFactor = sourceColor;
        color.sourceAlphaBlendFactor = sourceAlpha;
        color.destinationRGBBlendFactor = destinationColor;
        color.destinationAlphaBlendFactor = destinationAlpha;
        color.rgbBlendOperation = colorOperation;
        color.alphaBlendOperation = alphaOperation;
    }

    NSError *pipelineError = nil;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
    if (pipeline == nil) {
        error = metalErrorMessage(pipelineError, "Metal render pipeline creation failed");
    }
    return pipeline;
}

void ShaderRegistry::clear() {
    std::lock_guard lock(mutex_);
    shaders_.clear();
}

} // namespace shadermetal
