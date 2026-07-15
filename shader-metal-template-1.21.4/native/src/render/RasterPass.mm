#include "render/RasterPass.hpp"

#include "core/MetalDevice.hpp"
#include "render/PipelineCache.hpp"
#include "render/PipelineStateTracker.hpp"
#include "render/ShaderRegistry.hpp"
#include "resource/BufferManager.hpp"
#include "resource/SamplerCache.hpp"
#include "resource/TextureManager.hpp"
#include "resource/UniformStorage.hpp"

#include <algorithm>
#include <cstring>
#include <iterator>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <unordered_map>
#include <utility>

namespace shadermetal {
namespace {

constexpr std::size_t kSetBytesLimit = 4096;

struct CachedArgumentBuffer final {
    id<MTLArgumentEncoder> encoder = nil;
    id<MTLBuffer> buffer = nil;
    std::uint64_t bindingRevision = 0;
};

using ArgumentBufferCache = std::unordered_map<const void *, CachedArgumentBuffer>;

struct DrawCommand final {
    std::int32_t vertexId = -1;
    std::int32_t indexId = -1;
    std::int32_t shaderId = -1;
    std::int32_t indexCount = 0;
    std::int32_t indexType = -1;
    std::vector<std::byte> uniformData;
    std::int32_t instanceCount = 0;
    std::int32_t firstIndex = 0;
    std::int32_t firstVertex = 0;
    std::int32_t textureId = 0;
    std::array<float, 16> modelView{};
    std::array<float, 16> projection{};
    bool worldDraw = false;
    bool transientBuffers = true;
    PipelineKey pipelineState{};
};

void addError(RasterEncodeResult &result, RasterErrorCode code,
              std::size_t drawIndex, std::string message) {
    result.errors.push_back(RasterError{code, drawIndex, std::move(message)});
}

void eraseBuffers(std::vector<std::int32_t> &bufferIds) {
    std::sort(bufferIds.begin(), bufferIds.end());
    bufferIds.erase(std::unique(bufferIds.begin(), bufferIds.end()), bufferIds.end());
    for (const std::int32_t bufferId : bufferIds) {
        BufferManager::shared().erase(bufferId);
    }
    bufferIds.clear();
}

bool primitiveTypeForDrawMode(std::int32_t drawMode, MTLPrimitiveType &type,
                              std::string &error) {
    switch (drawMode) {
    case 0:
    case 2:
        type = MTLPrimitiveTypeLine;
        return true;
    case 1:
    case 3:
        type = MTLPrimitiveTypeLineStrip;
        return true;
    case 4:
    case 7:
        type = MTLPrimitiveTypeTriangle;
        return true;
    case 5:
        type = MTLPrimitiveTypeTriangleStrip;
        return true;
    case 6:
        error = "triangle-fan draw mode requires index conversion before Metal encoding";
        return false;
    default:
        error = "unsupported draw mode " + std::to_string(drawMode);
        return false;
    }
}

bool metalIndexType(std::int32_t indexType, MTLIndexType &type,
                    std::size_t &indexSize) {
    switch (indexType) {
    case 0:
        type = MTLIndexTypeUInt16;
        indexSize = sizeof(std::uint16_t);
        return true;
    case 1:
        type = MTLIndexTypeUInt32;
        indexSize = sizeof(std::uint32_t);
        return true;
    default:
        return false;
    }
}

bool metalCompareFunction(std::int32_t value, MTLCompareFunction &function) {
    switch (value) {
    case 0: function = MTLCompareFunctionNever; return true;
    case 1: function = MTLCompareFunctionLess; return true;
    case 2: function = MTLCompareFunctionEqual; return true;
    case 3: function = MTLCompareFunctionLessEqual; return true;
    case 4: function = MTLCompareFunctionGreater; return true;
    case 5: function = MTLCompareFunctionNotEqual; return true;
    case 6: function = MTLCompareFunctionGreaterEqual; return true;
    case 7: function = MTLCompareFunctionAlways; return true;
    default: return false;
    }
}

bool metalStencilOperation(std::int32_t value, MTLStencilOperation &operation) {
    switch (value) {
    case 0: operation = MTLStencilOperationKeep; return true;
    case 1: operation = MTLStencilOperationZero; return true;
    case 2: operation = MTLStencilOperationReplace; return true;
    case 3: operation = MTLStencilOperationIncrementClamp; return true;
    case 4: operation = MTLStencilOperationDecrementClamp; return true;
    case 5: operation = MTLStencilOperationInvert; return true;
    case 6: operation = MTLStencilOperationIncrementWrap; return true;
    case 7: operation = MTLStencilOperationDecrementWrap; return true;
    default: return false;
    }
}

MTLStencilDescriptor *createStencilDescriptor(const StencilFaceState &state,
                                               std::string &error) {
    MTLCompareFunction compare = MTLCompareFunctionAlways;
    MTLStencilOperation fail = MTLStencilOperationKeep;
    MTLStencilOperation depthFail = MTLStencilOperationKeep;
    MTLStencilOperation pass = MTLStencilOperationKeep;
    if (!metalCompareFunction(state.compareOperation, compare) ||
        !metalStencilOperation(state.failOperation, fail) ||
        !metalStencilOperation(state.depthFailOperation, depthFail) ||
        !metalStencilOperation(state.passOperation, pass)) {
        error = "stencil state contains an unsupported Vulkan enum";
        return nil;
    }

    MTLStencilDescriptor *descriptor = [[MTLStencilDescriptor alloc] init];
    descriptor.stencilCompareFunction = compare;
    descriptor.stencilFailureOperation = fail;
    descriptor.depthFailureOperation = depthFail;
    descriptor.depthStencilPassOperation = pass;
    descriptor.readMask = state.compareMask;
    descriptor.writeMask = state.writeMask;
    return descriptor;
}

id<MTLDepthStencilState> createDepthStencilState(id<MTLDevice> device,
                                                 const PipelineKey &state,
                                                 std::string &error) {
    MTLDepthStencilDescriptor *descriptor = [[MTLDepthStencilDescriptor alloc] init];
    descriptor.label = @"ShaderMetal Depth Stencil State";

    if (state.depthTestEnabled) {
        MTLCompareFunction compare = MTLCompareFunctionLess;
        if (!metalCompareFunction(state.depthCompareOperation, compare)) {
            error = "depth state contains an unsupported Vulkan compare enum";
            return nil;
        }
        descriptor.depthCompareFunction = compare;
        descriptor.depthWriteEnabled = state.depthWriteEnabled;
    } else {
        descriptor.depthCompareFunction = MTLCompareFunctionAlways;
        descriptor.depthWriteEnabled = NO;
    }

    if (state.stencilTestEnabled) {
        descriptor.frontFaceStencil = createStencilDescriptor(state.frontStencil, error);
        if (descriptor.frontFaceStencil == nil) {
            return nil;
        }
        descriptor.backFaceStencil = createStencilDescriptor(state.backStencil, error);
        if (descriptor.backFaceStencil == nil) {
            return nil;
        }
    } else {
        descriptor.frontFaceStencil = nil;
        descriptor.backFaceStencil = nil;
    }

    id<MTLDepthStencilState> depthStencil =
        [device newDepthStencilStateWithDescriptor:descriptor];
    if (depthStencil == nil) {
        error = "Metal failed to create a depth-stencil state";
    }
    return depthStencil;
}

std::span<const std::byte> uniformSpan(
    const std::optional<UniformSnapshot> &snapshot) {
    if (!snapshot.has_value()) {
        return {};
    }
    return snapshot->bytes;
}

bool bindBytes(id<MTLRenderCommandEncoder> encoder, id<MTLDevice> device,
               std::span<const std::byte> bytes, NSUInteger index,
               std::string &error) {
    if (bytes.empty()) {
        return true;
    }
    if (bytes.size() > std::numeric_limits<NSUInteger>::max()) {
        error = "uniform block exceeds Metal's NSUInteger range";
        return false;
    }

    const NSUInteger length = static_cast<NSUInteger>(bytes.size());
    if (bytes.size() <= kSetBytesLimit) {
        [encoder setVertexBytes:bytes.data() length:length atIndex:index];
        [encoder setFragmentBytes:bytes.data() length:length atIndex:index];
        return true;
    }

    id<MTLBuffer> buffer = [device newBufferWithBytes:bytes.data()
                                                  length:length
                                                 options:MTLResourceStorageModeShared];
    if (buffer == nil) {
        error = "Metal failed to allocate a transient uniform buffer";
        return false;
    }
    [encoder setVertexBuffer:buffer offset:0 atIndex:index];
    [encoder setFragmentBuffer:buffer offset:0 atIndex:index];
    return true;
}

bool bindDefaultResources(id<MTLRenderCommandEncoder> encoder, id<MTLDevice> device,
                          const ShaderRecord &shader,
                          const TextureManager::BindingSnapshot &textureSnapshot,
                          const DrawUniformBindings &uniforms,
                          ArgumentBufferCache &argumentBuffers,
                          std::string &error) {
    if (!bindBytes(encoder, device, uniforms.perDraw,
                   RasterPass::kPerDrawUniformBufferIndex, error) ||
        !bindBytes(encoder, device, uniforms.world,
                   RasterPass::kWorldUniformBufferIndex, error) ||
        !bindBytes(encoder, device, uniforms.sky,
                   RasterPass::kSkyUniformBufferIndex, error) ||
        !bindBytes(encoder, device, uniforms.overlayPost,
                   RasterPass::kOverlayPostUniformBufferIndex, error)) {
        return false;
    }

    const auto bindArgumentBuffer = [&](id<MTLFunction> function,
                                        MTLRenderStages stages,
                                        bool required) -> bool {
        if (!required) {
            return true;
        }
        const void *cacheKey = (__bridge const void *)function;
        ArgumentBufferCache::iterator cached;
        try {
            cached = argumentBuffers.try_emplace(cacheKey).first;
        } catch (const std::bad_alloc &) {
            error = "unable to cache the texture argument buffer";
            return false;
        }
        CachedArgumentBuffer &entry = cached->second;

        if (entry.encoder == nil) {
            entry.encoder = [function newArgumentEncoderWithBufferIndex:
                RasterPass::kTextureArgumentBufferIndex];
        }
        if (entry.encoder == nil || entry.encoder.encodedLength == 0) {
            error = "shader declares set 0 but Metal produced no argument encoder";
            return false;
        }
        if (entry.buffer == nil || entry.bindingRevision != textureSnapshot.revision) {
            id<MTLBuffer> argumentBuffer =
                [device newBufferWithLength:entry.encoder.encodedLength
                                    options:MTLResourceStorageModeShared];
            if (argumentBuffer == nil) {
                error = "Metal failed to allocate the texture argument buffer";
                return false;
            }
            if (argumentBuffer.contents == nullptr) {
                error = "texture argument buffer has no CPU-visible storage";
                return false;
            }
            std::memset(argumentBuffer.contents, 0,
                        static_cast<std::size_t>(argumentBuffer.length));
            [entry.encoder setArgumentBuffer:argumentBuffer offset:0];
            for (const TextureManager::TextureBinding &binding : textureSnapshot.bindings) {
                if (binding.textureId < 0 ||
                    static_cast<NSUInteger>(binding.textureId) >=
                        RasterPass::kTextureTableSize) {
                    error = "texture ID exceeds the fixed 4096-entry argument table";
                    return false;
                }
                std::string samplerError;
                id<MTLSamplerState> sampler = SamplerCache::shared().sampler(
                    device, binding.sampler, samplerError);
                if (sampler == nil) {
                    error = "texture " + std::to_string(binding.textureId) +
                        " has no usable sampler: " + samplerError;
                    return false;
                }
                const NSUInteger textureIndex = static_cast<NSUInteger>(binding.textureId);
                [entry.encoder setTexture:binding.texture atIndex:textureIndex];
                [entry.encoder setSamplerState:sampler
                                        atIndex:RasterPass::kTextureTableSize + textureIndex];
            }
            entry.buffer = argumentBuffer;
            entry.bindingRevision = textureSnapshot.revision;
        }

        if ((stages & MTLRenderStageVertex) != 0) {
            [encoder setVertexBuffer:entry.buffer
                              offset:0
                             atIndex:RasterPass::kTextureArgumentBufferIndex];
        }
        if ((stages & MTLRenderStageFragment) != 0) {
            [encoder setFragmentBuffer:entry.buffer
                                offset:0
                               atIndex:RasterPass::kTextureArgumentBufferIndex];
        }
        return true;
    };

    return bindArgumentBuffer(shader.vertexFunction, MTLRenderStageVertex,
                              shader.vertexUsesArgumentBuffer) &&
        bindArgumentBuffer(shader.fragmentFunction, MTLRenderStageFragment,
                           shader.fragmentUsesArgumentBuffer);
}

enum class DynamicStateResult {
    Applied,
    SkipDraw,
    Error,
};

DynamicStateResult applyDynamicState(id<MTLRenderCommandEncoder> encoder,
                                     const PipelineKey &state,
                                     MTLPrimitiveType primitiveType,
                                     NSUInteger targetWidth,
                                     NSUInteger targetHeight,
                                     std::string &error) {
    const bool trianglePrimitive = primitiveType == MTLPrimitiveTypeTriangle ||
        primitiveType == MTLPrimitiveTypeTriangleStrip;

    MTLViewport viewport;
    if (state.viewport.width > 0 && state.viewport.height > 0) {
        viewport.originX = state.viewport.x;
        viewport.originY = static_cast<double>(targetHeight) -
            static_cast<double>(state.viewport.y) - state.viewport.height;
        viewport.width = state.viewport.width;
        viewport.height = state.viewport.height;
    } else {
        viewport.originX = 0.0;
        viewport.originY = 0.0;
        viewport.width = targetWidth;
        viewport.height = targetHeight;
    }
    viewport.znear = 0.0;
    viewport.zfar = 1.0;
    [encoder setViewport:viewport];

    if (state.scissorEnabled) {
        if (state.scissor.width <= 0 || state.scissor.height <= 0) {
            error = "scissor has no drawable area";
            return DynamicStateResult::SkipDraw;
        }
        const std::int64_t left = state.scissor.x;
        const std::int64_t top = static_cast<std::int64_t>(targetHeight) -
            static_cast<std::int64_t>(state.scissor.y) - state.scissor.height;
        const std::int64_t right = left + state.scissor.width;
        const std::int64_t bottom = top + state.scissor.height;
        const std::int64_t clippedLeft = std::clamp<std::int64_t>(left, 0, targetWidth);
        const std::int64_t clippedTop = std::clamp<std::int64_t>(top, 0, targetHeight);
        const std::int64_t clippedRight = std::clamp<std::int64_t>(right, 0, targetWidth);
        const std::int64_t clippedBottom = std::clamp<std::int64_t>(bottom, 0, targetHeight);
        if (clippedRight <= clippedLeft || clippedBottom <= clippedTop) {
            error = "scissor is outside the drawable";
            return DynamicStateResult::SkipDraw;
        }
        [encoder setScissorRect:MTLScissorRect{
            static_cast<NSUInteger>(clippedLeft),
            static_cast<NSUInteger>(clippedTop),
            static_cast<NSUInteger>(clippedRight - clippedLeft),
            static_cast<NSUInteger>(clippedBottom - clippedTop)}];
    } else {
        [encoder setScissorRect:MTLScissorRect{0, 0, targetWidth, targetHeight}];
    }

    [encoder setBlendColorRed:state.blendConstants[0].toFloat()
                        green:state.blendConstants[1].toFloat()
                         blue:state.blendConstants[2].toFloat()
                        alpha:state.blendConstants[3].toFloat()];

    switch (state.frontFace) {
    case 0: [encoder setFrontFacingWinding:MTLWindingCounterClockwise]; break;
    case 1: [encoder setFrontFacingWinding:MTLWindingClockwise]; break;
    default:
        error = "unsupported Vulkan front-face enum";
        return DynamicStateResult::Error;
    }

    switch (state.cullMode) {
    case 0: [encoder setCullMode:MTLCullModeNone]; break;
    case 1: [encoder setCullMode:MTLCullModeFront]; break;
    case 2: [encoder setCullMode:MTLCullModeBack]; break;
    case 3:
        if (trianglePrimitive) {
            error = "front-and-back culling rejects the triangle draw";
            return DynamicStateResult::SkipDraw;
        }
        [encoder setCullMode:MTLCullModeNone];
        break;
    default:
        error = "unsupported Vulkan cull-mode flags";
        return DynamicStateResult::Error;
    }

    if (trianglePrimitive) {
        switch (state.polygonMode) {
        case 0: [encoder setTriangleFillMode:MTLTriangleFillModeFill]; break;
        case 1: [encoder setTriangleFillMode:MTLTriangleFillModeLines]; break;
        case 2:
            error = "Metal has no triangle point-fill mode";
            return DynamicStateResult::Error;
        default:
            error = "unsupported Vulkan polygon-mode enum";
            return DynamicStateResult::Error;
        }
    }

    if ((primitiveType == MTLPrimitiveTypeLine ||
         primitiveType == MTLPrimitiveTypeLineStrip || state.polygonMode == 1) &&
        state.lineWidth.bits != FloatBits::fromFloat(1.0F).bits) {
        error = "Metal does not support programmable raster line width";
        return DynamicStateResult::Error;
    }

    const auto polygonModeIndex = static_cast<std::size_t>(state.polygonMode);
    const bool depthBiasEnabled =
        polygonModeIndex < state.depthBiasEnabledByPolygonMode.size() &&
        state.depthBiasEnabledByPolygonMode[polygonModeIndex];
    if (depthBiasEnabled) {
        [encoder setDepthBias:state.depthBiasConstantFactor.toFloat()
                    slopeScale:state.depthBiasSlopeFactor.toFloat()
                         clamp:0.0F];
    } else {
        [encoder setDepthBias:0.0F slopeScale:0.0F clamp:0.0F];
    }

    [encoder setStencilFrontReferenceValue:state.frontStencil.reference
                        backReferenceValue:state.backStencil.reference];
    return DynamicStateResult::Applied;
}

} // namespace

struct RasterPass::Impl final {
    mutable std::mutex queueMutex;
    bool acceptingDraws = false;
    bool encodingPrepared = false;
    std::vector<DrawCommand> queuedDraws;
    std::vector<DrawCommand> encodingDraws;
    std::optional<std::size_t> worldDrawCount;
    std::vector<std::int32_t> encodedTransientBufferIds;
    std::vector<std::int32_t> deferredBufferReleases;

    mutable std::mutex resourceBinderMutex;
    ResourceBinder resourceBinder;

    mutable std::mutex cacheMutex;
    id<MTLDevice> cacheDevice = nil;
    std::unique_ptr<PipelineCache> pipelineCache;
    std::unordered_map<PipelineKey, id<MTLDepthStencilState>, PipelineKeyHash>
        depthStencilStates;
    ArgumentBufferCache argumentBuffers;
};

RasterPass &RasterPass::shared() {
    static RasterPass pass;
    return pass;
}

RasterPass::RasterPass() : impl_(std::make_unique<Impl>()) {}

RasterPass::~RasterPass() = default;

void RasterPass::beginFrame() {
    discardFrame();
    releaseEncodedTransientBuffers();
    std::vector<std::int32_t> deferredReleases;
    {
        std::lock_guard lock(impl_->queueMutex);
        deferredReleases.swap(impl_->deferredBufferReleases);
    }
    // FrameContext uses -commandBuffer, not the unretained variant, so Metal
    // keeps encoded resources alive while the GPU is in flight. Delay Java
    // releases to this boundary so close/re-upload cannot invalidate queued draws.
    eraseBuffers(deferredReleases);
    {
        std::lock_guard lock(impl_->queueMutex);
        impl_->worldDrawCount.reset();
        impl_->encodingPrepared = false;
        impl_->acceptingDraws = true;
    }
}

bool RasterPass::enqueueDraw(std::int32_t vertexId, std::int32_t indexId,
                             std::int32_t shaderId, std::int32_t indexCount,
                             std::int32_t indexType, const void *uniformData,
                             std::size_t uniformSize, std::int32_t instanceCount,
                             std::int32_t firstIndex, std::int32_t firstVertex,
                             const void *matrixData, std::int32_t textureId,
                             bool worldDraw, bool transientBuffers,
                             std::string &error) {
    error.clear();
    if (vertexId < 0 || indexId < 0 || shaderId < 0) {
        error = "draw references a negative resource ID";
        return false;
    }
    if (indexCount < 0 || instanceCount < 0 || firstIndex < 0) {
        error = "draw count, instance count, and first index must be nonnegative";
        return false;
    }
    if (indexType != 0 && indexType != 1) {
        error = "draw index type must be 0 (uint16) or 1 (uint32)";
        return false;
    }
    if (uniformSize != 0 && uniformData == nullptr) {
        error = "draw uniform pointer is null for a nonempty uniform block";
        return false;
    }
    if (matrixData == nullptr) {
        error = "draw matrix pointer is null";
        return false;
    }
    if (textureId < 0) {
        error = "draw texture ID must be nonnegative";
        return false;
    }

    const std::optional<ShaderRecord> shader = ShaderRegistry::shared().shader(shaderId);
    if (!shader.has_value()) {
        error = "draw references an unregistered shader ID";
        return false;
    }
    if (shader->uniformSize != uniformSize) {
        error = "draw uniform size does not match the registered shader uniform size";
        return false;
    }

    DrawCommand command;
    command.vertexId = vertexId;
    command.indexId = indexId;
    command.shaderId = shaderId;
    command.indexCount = indexCount;
    command.indexType = indexType;
    command.instanceCount = instanceCount;
    command.firstIndex = firstIndex;
    command.firstVertex = firstVertex;
    command.textureId = textureId;
    command.worldDraw = worldDraw;
    command.transientBuffers = transientBuffers;
    command.pipelineState = PipelineStateTracker::shared().snapshot();
    try {
        const auto *bytes = static_cast<const std::byte *>(uniformData);
        if (uniformSize != 0) {
            command.uniformData.assign(bytes, bytes + uniformSize);
        }
        const auto *matrices = static_cast<const float *>(matrixData);
        std::copy_n(matrices, command.modelView.size(), command.modelView.begin());
        std::copy_n(matrices + command.modelView.size(), command.projection.size(),
                    command.projection.begin());
    } catch (const std::bad_alloc &) {
        error = "unable to retain per-draw uniform bytes";
        return false;
    }

    std::lock_guard lock(impl_->queueMutex);
    if (!impl_->acceptingDraws) {
        error = "draw was submitted outside an acquired frame";
        return false;
    }
    try {
        impl_->queuedDraws.push_back(std::move(command));
    } catch (const std::bad_alloc &) {
        error = "unable to enqueue draw command";
        return false;
    }
    return true;
}

void RasterPass::sealWorld() {
    std::lock_guard lock(impl_->queueMutex);
    if (impl_->acceptingDraws && !impl_->worldDrawCount.has_value()) {
        impl_->worldDrawCount = impl_->queuedDraws.size();
    }
}

std::vector<RayTracingDraw> RasterPass::rayTracingDraws() const {
    std::vector<RayTracingDraw> result;
    std::lock_guard lock(impl_->queueMutex);
    const std::vector<DrawCommand> &draws = impl_->encodingPrepared
        ? impl_->encodingDraws
        : impl_->queuedDraws;
    const std::size_t worldCount = std::min(
        impl_->worldDrawCount.value_or(0), draws.size());
    result.reserve(worldCount);
    for (std::size_t index = 0; index < worldCount; ++index) {
        const DrawCommand &draw = draws[index];
        if (!draw.worldDraw) {
            continue;
        }
        result.push_back(RayTracingDraw{
            draw.vertexId,
            draw.indexId,
            draw.shaderId,
            draw.indexCount,
            draw.indexType,
            draw.firstIndex,
            draw.firstVertex,
            draw.textureId,
            draw.modelView,
            draw.projection,
            draw.instanceCount,
            draw.worldDraw,
            draw.transientBuffers,
            draw.pipelineState.blendEnabled,
        });
    }
    return result;
}

bool RasterPass::deferBufferRelease(std::int32_t bufferId, std::string &error) {
    error.clear();
    if (bufferId <= 0) {
        error = "buffer release ID must be positive";
        return false;
    }

    std::lock_guard lock(impl_->queueMutex);
    try {
        impl_->deferredBufferReleases.push_back(bufferId);
    } catch (const std::bad_alloc &) {
        error = "unable to defer native buffer release";
        return false;
    }
    return true;
}

RasterEncodeResult RasterPass::encodeQueuedDraws(id<MTLRenderCommandEncoder> encoder,
                                                  NSUInteger targetWidth,
                                                  NSUInteger targetHeight,
                                                  RasterPartition partition) {
    RasterEncodeResult result;
    const std::vector<DrawCommand> *drawsPointer = nullptr;
    std::size_t rangeBegin = 0;
    std::size_t rangeEnd = 0;
    {
        std::lock_guard lock(impl_->queueMutex);
        impl_->acceptingDraws = false;
        if (!impl_->encodingPrepared) {
            impl_->encodingDraws.swap(impl_->queuedDraws);
            impl_->encodingPrepared = true;
            try {
                impl_->encodedTransientBufferIds.reserve(
                    impl_->encodedTransientBufferIds.size() +
                    impl_->encodingDraws.size() * 2U);
                for (const DrawCommand &draw : impl_->encodingDraws) {
                    if (draw.transientBuffers) {
                        impl_->encodedTransientBufferIds.push_back(draw.vertexId);
                        impl_->encodedTransientBufferIds.push_back(draw.indexId);
                    }
                }
            } catch (const std::bad_alloc &) {
                addError(result, RasterErrorCode::InvalidCommand, 0,
                         "unable to retain transient buffer IDs for frame-end release");
            }
        }
        drawsPointer = &impl_->encodingDraws;
        const std::size_t drawCount = impl_->encodingDraws.size();
        switch (partition) {
        case RasterPartition::All:
            rangeEnd = drawCount;
            break;
        case RasterPartition::World:
        case RasterPartition::Ui:
            rangeEnd = drawCount;
            break;
        }
    }
    const std::vector<DrawCommand> &draws = *drawsPointer;
    result.submittedDrawCount = static_cast<std::size_t>(std::count_if(
        draws.begin() + static_cast<std::ptrdiff_t>(rangeBegin),
        draws.begin() + static_cast<std::ptrdiff_t>(rangeEnd),
        [partition](const DrawCommand &draw) {
            return partition == RasterPartition::All ||
                (partition == RasterPartition::World && draw.worldDraw) ||
                (partition == RasterPartition::Ui && !draw.worldDraw);
        }));

    if (encoder == nil || targetWidth == 0 || targetHeight == 0) {
        if (!draws.empty()) {
            addError(result, RasterErrorCode::InvalidCommand, 0,
                     "raster encoding requires an encoder and nonempty target");
        }
        return result;
    }

    id<MTLDevice> device = MetalDevice::shared().device();
    if (device == nil) {
        addError(result, RasterErrorCode::PipelineCreation, 0,
                 "Metal device is unavailable during raster encoding");
        return result;
    }

    {
        std::lock_guard lock(impl_->cacheMutex);
        if (impl_->cacheDevice != device) {
            impl_->pipelineCache.reset();
            impl_->depthStencilStates.clear();
            impl_->argumentBuffers.clear();
            impl_->cacheDevice = device;
        }
        if (!impl_->pipelineCache) {
            impl_->pipelineCache = std::make_unique<PipelineCache>(
                [device](std::int32_t shaderId, const PipelineKey &state,
                         std::string &error) {
                    return ShaderRegistry::shared().createRenderPipelineState(
                        shaderId, state, device, error);
                });
        }
    }

    ResourceBinder resourceBinder;
    {
        std::lock_guard lock(impl_->resourceBinderMutex);
        resourceBinder = impl_->resourceBinder;
    }

    const std::optional<UniformSnapshot> world =
        UniformStorage::shared().snapshot(UniformSlot::World);
    const std::optional<UniformSnapshot> sky =
        UniformStorage::shared().snapshot(UniformSlot::Sky);
    const std::optional<UniformSnapshot> overlay =
        UniformStorage::shared().snapshot(UniformSlot::OverlayPost);
    const TextureManager::BindingSnapshot textureBindings =
        TextureManager::shared().bindingSnapshot();
    for (const TextureManager::TextureBinding &binding : textureBindings.bindings) {
        [encoder useResource:binding.texture
                       usage:MTLResourceUsageRead
                      stages:MTLRenderStageVertex | MTLRenderStageFragment];
    }

    std::int32_t cachedShaderId = ShaderRegistry::kInvalidShaderId;
    std::optional<ShaderRecord> cachedShader;
    bool hasCachedPipelineState = false;
    PipelineKey cachedPipelineState{};
    std::int32_t cachedPipelineShaderId = ShaderRegistry::kInvalidShaderId;
    id<MTLRenderPipelineState> cachedPipeline = nil;
    id<MTLDepthStencilState> cachedDepthStencil = nil;
    id<MTLRenderPipelineState> boundPipeline = nil;
    id<MTLDepthStencilState> boundDepthStencil = nil;
    id<MTLBuffer> boundVertexBuffer = nil;

    for (std::size_t drawIndex = rangeBegin; drawIndex < rangeEnd; ++drawIndex) {
        const DrawCommand &draw = draws[drawIndex];
        if ((partition == RasterPartition::World && !draw.worldDraw) ||
            (partition == RasterPartition::Ui && draw.worldDraw)) {
            continue;
        }
        if (draw.indexCount == 0 || draw.instanceCount == 0) {
            ++result.skippedDrawCount;
            if (result.firstSkippedReason.empty()) {
                result.firstSkippedReason = "draw has a zero index or instance count";
            }
            continue;
        }

        if (cachedShaderId != draw.shaderId) {
            cachedShader = ShaderRegistry::shared().shader(draw.shaderId);
            cachedShaderId = draw.shaderId;
        }
        if (!cachedShader.has_value()) {
            addError(result, RasterErrorCode::MissingShader, drawIndex,
                     "draw shader was removed before encoding");
            continue;
        }

        id<MTLBuffer> vertexBuffer = BufferManager::shared().buffer(draw.vertexId);
        if (vertexBuffer == nil) {
            addError(result, RasterErrorCode::MissingVertexBuffer, drawIndex,
                     "draw vertex buffer is not initialized");
            continue;
        }
        id<MTLBuffer> indexBuffer = BufferManager::shared().buffer(draw.indexId);
        if (indexBuffer == nil) {
            addError(result, RasterErrorCode::MissingIndexBuffer, drawIndex,
                     "draw index buffer is not initialized");
            continue;
        }

        MTLIndexType indexType = MTLIndexTypeUInt16;
        std::size_t indexSize = 0;
        if (!metalIndexType(draw.indexType, indexType, indexSize)) {
            addError(result, RasterErrorCode::InvalidCommand, drawIndex,
                     "draw has an unsupported index type");
            continue;
        }
        const std::size_t firstIndex = static_cast<std::size_t>(draw.firstIndex);
        const std::size_t indexCount = static_cast<std::size_t>(draw.indexCount);
        if (firstIndex > std::numeric_limits<std::size_t>::max() / indexSize ||
            indexCount > std::numeric_limits<std::size_t>::max() / indexSize) {
            addError(result, RasterErrorCode::BufferRange, drawIndex,
                     "draw index range overflows size_t");
            continue;
        }
        const std::size_t indexOffset = firstIndex * indexSize;
        const std::size_t indexBytes = indexCount * indexSize;
        const std::size_t bufferSize = BufferManager::shared().size(draw.indexId);
        if (indexOffset > bufferSize || indexBytes > bufferSize - indexOffset) {
            addError(result, RasterErrorCode::BufferRange, drawIndex,
                     "draw index range exceeds the index buffer");
            continue;
        }

        std::string error;
        id<MTLRenderPipelineState> pipeline = nil;
        id<MTLDepthStencilState> depthStencil = nil;
        if (hasCachedPipelineState && cachedPipelineShaderId == draw.shaderId &&
            cachedPipelineState == draw.pipelineState) {
            pipeline = cachedPipeline;
            depthStencil = cachedDepthStencil;
        } else {
            std::lock_guard lock(impl_->cacheMutex);
            pipeline = impl_->pipelineCache->getOrCreate(
                draw.shaderId, draw.pipelineState, error);
            if (pipeline != nil) {
                const auto found = impl_->depthStencilStates.find(draw.pipelineState);
                if (found != impl_->depthStencilStates.end()) {
                    depthStencil = found->second;
                } else {
                    depthStencil = createDepthStencilState(device, draw.pipelineState, error);
                    if (depthStencil != nil) {
                        impl_->depthStencilStates.emplace(draw.pipelineState, depthStencil);
                    }
                }
            }
            if (pipeline != nil && depthStencil != nil) {
                hasCachedPipelineState = true;
                cachedPipelineState = draw.pipelineState;
                cachedPipelineShaderId = draw.shaderId;
                cachedPipeline = pipeline;
                cachedDepthStencil = depthStencil;
            }
        }
        if (pipeline == nil) {
            addError(result, RasterErrorCode::PipelineCreation, drawIndex,
                     error.empty() ? "render pipeline creation failed" : error);
            continue;
        }
        if (depthStencil == nil) {
            addError(result, RasterErrorCode::DepthStencilCreation, drawIndex,
                     error.empty() ? "depth-stencil creation failed" : error);
            continue;
        }

        MTLPrimitiveType primitiveType = MTLPrimitiveTypeTriangle;
        if (!primitiveTypeForDrawMode(cachedShader->drawMode, primitiveType, error)) {
            addError(result, RasterErrorCode::UnsupportedState, drawIndex, error);
            continue;
        }

        if (boundPipeline != pipeline) {
            [encoder setRenderPipelineState:pipeline];
            boundPipeline = pipeline;
        }
        if (boundDepthStencil != depthStencil) {
            [encoder setDepthStencilState:depthStencil];
            boundDepthStencil = depthStencil;
        }
        if (boundVertexBuffer != vertexBuffer) {
            [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:kVertexBufferIndex];
            boundVertexBuffer = vertexBuffer;
        }

        const DynamicStateResult dynamicResult = applyDynamicState(
            encoder, draw.pipelineState, primitiveType, targetWidth, targetHeight, error);
        if (dynamicResult == DynamicStateResult::SkipDraw) {
            ++result.skippedDrawCount;
            if (result.firstSkippedReason.empty()) {
                result.firstSkippedReason = error.empty()
                    ? "dynamic raster state rejected the draw"
                    : error;
            }
            continue;
        }
        if (dynamicResult == DynamicStateResult::Error) {
            addError(result, RasterErrorCode::UnsupportedState, drawIndex, error);
            continue;
        }

        const DrawUniformBindings uniforms{
            draw.uniformData,
            uniformSpan(world),
            uniformSpan(sky),
            uniformSpan(overlay),
        };
        if (resourceBinder) {
            if (!resourceBinder(encoder, draw.shaderId, uniforms, error)) {
                addError(result, RasterErrorCode::ResourceBinding, drawIndex,
                         error.empty() ? "resource binder rejected the draw" : error);
                continue;
            }
        } else if (!bindDefaultResources(encoder, device, *cachedShader,
                                         textureBindings, uniforms,
                                         impl_->argumentBuffers, error)) {
            addError(result, RasterErrorCode::ResourceBinding, drawIndex, error);
            continue;
        }

        [encoder drawIndexedPrimitives:primitiveType
                            indexCount:static_cast<NSUInteger>(indexCount)
                             indexType:indexType
                           indexBuffer:indexBuffer
                     indexBufferOffset:static_cast<NSUInteger>(indexOffset)
                         instanceCount:static_cast<NSUInteger>(draw.instanceCount)
                            baseVertex:static_cast<NSInteger>(draw.firstVertex)
                          baseInstance:0];
        ++result.encodedDrawCount;
    }

    return result;
}

void RasterPass::releaseEncodedTransientBuffers() {
    std::vector<std::int32_t> bufferIds;
    {
        std::lock_guard lock(impl_->queueMutex);
        bufferIds.swap(impl_->encodedTransientBufferIds);
        impl_->encodingDraws.clear();
        impl_->encodingPrepared = false;
        impl_->worldDrawCount.reset();
    }
    eraseBuffers(bufferIds);
}

void RasterPass::discardFrame() {
    std::vector<DrawCommand> draws;
    {
        std::lock_guard lock(impl_->queueMutex);
        impl_->acceptingDraws = false;
        draws.swap(impl_->queuedDraws);
        draws.insert(draws.end(),
                     std::make_move_iterator(impl_->encodingDraws.begin()),
                     std::make_move_iterator(impl_->encodingDraws.end()));
        impl_->encodingDraws.clear();
        impl_->encodingPrepared = false;
        impl_->worldDrawCount.reset();
    }
    for (const DrawCommand &draw : draws) {
        if (draw.transientBuffers) {
            BufferManager::shared().erase(draw.vertexId);
            if (draw.indexId != draw.vertexId) {
                BufferManager::shared().erase(draw.indexId);
            }
        }
    }
}

void RasterPass::close() {
    discardFrame();
    releaseEncodedTransientBuffers();
    std::vector<std::int32_t> deferredReleases;
    {
        std::lock_guard lock(impl_->queueMutex);
        deferredReleases.swap(impl_->deferredBufferReleases);
    }
    eraseBuffers(deferredReleases);
    {
        std::lock_guard lock(impl_->cacheMutex);
        impl_->pipelineCache.reset();
        impl_->depthStencilStates.clear();
        impl_->argumentBuffers.clear();
        impl_->cacheDevice = nil;
    }
    {
        std::lock_guard lock(impl_->resourceBinderMutex);
        impl_->resourceBinder = {};
    }
    ShaderRegistry::shared().clear();
}

void RasterPass::setResourceBinder(ResourceBinder binder) {
    std::lock_guard lock(impl_->resourceBinderMutex);
    impl_->resourceBinder = std::move(binder);
}

std::size_t RasterPass::queuedDrawCount() const {
    std::lock_guard lock(impl_->queueMutex);
    return impl_->queuedDraws.size() + impl_->encodingDraws.size();
}

} // namespace shadermetal
