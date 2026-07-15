#include "raytracing/AccelStructManager.hpp"

#include "resource/BufferManager.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace shadermetal {
namespace {

constexpr std::int32_t kTerrainVertexFormat = 0;
constexpr std::size_t kTerrainVertexStride = 32;
constexpr std::int32_t kEntityVertexFormat = 1;
constexpr std::size_t kEntityVertexStride = 36;
constexpr std::int32_t kTriangleDrawMode = 4;
constexpr std::int32_t kQuadDrawMode = 7;
constexpr std::size_t kInitialCanonicalVertexCapacity = 65'536;
constexpr std::uint32_t kPersistentVertexUsage = 0x80U;
constexpr std::uint32_t kPersistentIndexUsage = 0x40U;
constexpr std::uint64_t kDynamicGeometrySerial =
    std::numeric_limits<std::uint64_t>::max();
constexpr std::uint64_t kLocalPlayerGeometrySerial =
    std::numeric_limits<std::uint64_t>::max() - 1U;
constexpr std::size_t kMaximumObservedDynamicDraws = 512;
constexpr std::size_t kDynamicFramesInFlight = 3;
constexpr std::uint64_t kCanonicalReuseDelayFrames = 4;
constexpr std::size_t kInitialDynamicVertexCapacity = 4'096;
constexpr std::size_t kInitialDynamicScratchCapacity = 64U * 1'024U;
constexpr std::uint64_t kInvisibleTerrainRetentionFrames = 16;
constexpr std::size_t kMaximumInvisibleTerrainInstances = 1'024;
constexpr double kMaximumAnchorDistance = 8'192.0;
constexpr std::uint32_t kDynamicTextureIdMask = 0x0000'0FFFU;
constexpr std::uint32_t kDynamicTextureAlphaTestBit = 1U << 30U;
constexpr std::uint32_t kDynamicTextureTranslucentBit = 1U << 31U;
constexpr std::uint32_t kWorldInstanceMask = 0x01U;
constexpr std::uint32_t kLocalPlayerShadowInstanceMask = 0x02U;
constexpr std::uint32_t kProxyTextureId = kDynamicTextureIdMask;
constexpr std::size_t kLocalPlayerBoxCount = 6;
constexpr std::size_t kTrianglesPerBox = 12;
constexpr std::size_t kVerticesPerBox = kTrianglesPerBox * 3;
constexpr std::size_t kLocalPlayerProxyVertexCount =
    kLocalPlayerBoxCount * kVerticesPerBox;

MTLAccelerationStructureUsage accelerationStructureUsage(bool refittable) {
    MTLAccelerationStructureUsage usage = refittable
        ? MTLAccelerationStructureUsageRefit
        : MTLAccelerationStructureUsageNone;
    if (@available(macOS 26.0, *)) {
        usage |= MTLAccelerationStructureUsagePreferFastIntersection;
    }
    return usage;
}

bool checkedAdd(std::size_t left, std::size_t right, std::size_t &result) {
    if (right > std::numeric_limits<std::size_t>::max() - left) {
        return false;
    }
    result = left + right;
    return true;
}

bool checkedMultiply(std::size_t left, std::size_t right, std::size_t &result) {
    if (left != 0 && right > std::numeric_limits<std::size_t>::max() / left) {
        return false;
    }
    result = left * right;
    return true;
}

template <typename T>
void hashCombine(std::size_t &seed, const T &value) {
    const std::size_t hash = std::hash<T>{}(value);
    seed ^= hash + 0x9e3779b97f4a7c15ULL + (seed << 6U) + (seed >> 2U);
}

bool finiteMatrix(const std::array<float, 16> &matrix) {
    return std::all_of(matrix.begin(), matrix.end(), [](float value) {
        return std::isfinite(value);
    });
}

std::array<float, 16> identityMatrix() {
    return {
        1.0F, 0.0F, 0.0F, 0.0F,
        0.0F, 1.0F, 0.0F, 0.0F,
        0.0F, 0.0F, 1.0F, 0.0F,
        0.0F, 0.0F, 0.0F, 1.0F,
    };
}

std::array<float, 12> paddedLinearColumns(
    const std::array<float, 16> &matrix) {
    return {
        matrix[0], matrix[1], matrix[2], 0.0F,
        matrix[4], matrix[5], matrix[6], 0.0F,
        matrix[8], matrix[9], matrix[10], 0.0F,
    };
}

bool affineModelView(const std::array<float, 16> &matrix) {
    constexpr float epsilon = 1.0e-4F;
    return std::abs(matrix[3]) <= epsilon &&
           std::abs(matrix[7]) <= epsilon &&
           std::abs(matrix[11]) <= epsilon &&
           std::abs(matrix[15] - 1.0F) <= epsilon;
}

bool normalMatrixForModelView(const std::array<float, 16> &matrix,
                              std::array<float, 12> &normalToView) {
    const float a00 = matrix[0];
    const float a01 = matrix[4];
    const float a02 = matrix[8];
    const float a10 = matrix[1];
    const float a11 = matrix[5];
    const float a12 = matrix[9];
    const float a20 = matrix[2];
    const float a21 = matrix[6];
    const float a22 = matrix[10];

    const float c00 = a11 * a22 - a12 * a21;
    const float c01 = a12 * a20 - a10 * a22;
    const float c02 = a10 * a21 - a11 * a20;
    const float c10 = a02 * a21 - a01 * a22;
    const float c11 = a00 * a22 - a02 * a20;
    const float c12 = a01 * a20 - a00 * a21;
    const float c20 = a01 * a12 - a02 * a11;
    const float c21 = a02 * a10 - a00 * a12;
    const float c22 = a00 * a11 - a01 * a10;
    const float determinant = a00 * c00 + a01 * c01 + a02 * c02;
    if (!std::isfinite(determinant) || std::abs(determinant) < 1.0e-8F) {
        return false;
    }

    const float inverseDeterminant = 1.0F / determinant;
    // Cofactor(A) is inverse-transpose(A). Store its three columns padded to
    // float4 so the MSL side has an unambiguous, naturally aligned layout.
    normalToView = {
        c00 * inverseDeterminant,
        c10 * inverseDeterminant,
        c20 * inverseDeterminant,
        0.0F,
        c01 * inverseDeterminant,
        c11 * inverseDeterminant,
        c21 * inverseDeterminant,
        0.0F,
        c02 * inverseDeterminant,
        c12 * inverseDeterminant,
        c22 * inverseDeterminant,
        0.0F,
    };
    return std::all_of(normalToView.begin(), normalToView.end(), [](float value) {
        return std::isfinite(value);
    });
}

MTLPackedFloat4x3 packedTransform(const std::array<float, 16> &matrix) {
    return MTLPackedFloat4x3(
        MTLPackedFloat3(matrix[0], matrix[1], matrix[2]),
        MTLPackedFloat3(matrix[4], matrix[5], matrix[6]),
        MTLPackedFloat3(matrix[8], matrix[9], matrix[10]),
        MTLPackedFloat3(matrix[12], matrix[13], matrix[14]));
}

std::array<float, 16> multiplyMatrices(const std::array<float, 16> &left,
                                       const std::array<float, 16> &right) {
    std::array<float, 16> product{};
    for (std::size_t column = 0; column < 4; ++column) {
        for (std::size_t row = 0; row < 4; ++row) {
            float value = 0.0F;
            for (std::size_t inner = 0; inner < 4; ++inner) {
                value += left[inner * 4 + row] * right[column * 4 + inner];
            }
            product[column * 4 + row] = value;
        }
    }
    return product;
}

bool transformPosition(const std::array<float, 16> &matrix,
                       const float source[3], float destination[3]) {
    for (std::size_t row = 0; row < 3; ++row) {
        destination[row] = matrix[row] * source[0] +
                           matrix[4 + row] * source[1] +
                           matrix[8 + row] * source[2] + matrix[12 + row];
    }
    return std::all_of(destination, destination + 3, [](float value) {
        return std::isfinite(value);
    });
}

bool transformPackedNormal(const std::array<float, 12> &normalToScene,
                           const std::int8_t source[3],
                           std::int8_t destination[4]) {
    float unpacked[3]{};
    for (std::size_t index = 0; index < 3; ++index) {
        unpacked[index] = std::max(-1.0F,
            static_cast<float>(source[index]) / 127.0F);
    }

    float transformed[3]{};
    for (std::size_t row = 0; row < 3; ++row) {
        transformed[row] = normalToScene[row] * unpacked[0] +
                           normalToScene[4 + row] * unpacked[1] +
                           normalToScene[8 + row] * unpacked[2];
    }
    const float lengthSquared = transformed[0] * transformed[0] +
                                transformed[1] * transformed[1] +
                                transformed[2] * transformed[2];
    if (!std::isfinite(lengthSquared)) {
        return false;
    }
    if (lengthSquared <= 1.0e-12F) {
        destination[0] = 0;
        destination[1] = 127;
        destination[2] = 0;
        destination[3] = 0;
        return true;
    }

    const float inverseLength = 1.0F / std::sqrt(lengthSquared);
    for (std::size_t index = 0; index < 3; ++index) {
        const float normalized = std::clamp(
            transformed[index] * inverseLength, -1.0F, 1.0F);
        destination[index] = static_cast<std::int8_t>(
            std::lround(normalized * 127.0F));
    }
    destination[3] = 0;
    return true;
}

bool dynamicSceneBounds(const std::vector<RTVertex> &vertices,
                        std::size_t firstVertex,
                        std::size_t vertexCount,
                        std::array<float, 3> &minimum,
                        std::array<float, 3> &maximum) {
    if (vertexCount == 0 || firstVertex > vertices.size() ||
        vertexCount > vertices.size() - firstVertex) {
        return false;
    }
    const RTVertex &first = vertices[firstVertex];
    minimum = {first.position[0], first.position[1], first.position[2]};
    maximum = minimum;
    for (std::size_t index = firstVertex;
         index < firstVertex + vertexCount; ++index) {
        const RTVertex &vertex = vertices[index];
        for (std::size_t axis = 0; axis < 3; ++axis) {
            if (!std::isfinite(vertex.position[axis])) {
                return false;
            }
            minimum[axis] = std::min(minimum[axis], vertex.position[axis]);
            maximum[axis] = std::max(maximum[axis], vertex.position[axis]);
        }
    }
    return true;
}

bool boundsContained(const std::array<float, 3> &innerMinimum,
                     const std::array<float, 3> &innerMaximum,
                     const std::array<float, 3> &outerMinimum,
                     const std::array<float, 3> &outerMaximum) {
    constexpr float epsilon = 1.0e-3F;
    for (std::size_t axis = 0; axis < 3; ++axis) {
        if (innerMinimum[axis] < outerMinimum[axis] - epsilon ||
            innerMaximum[axis] > outerMaximum[axis] + epsilon) {
            return false;
        }
    }
    return true;
}

bool inverseAffineMatrix(const std::array<float, 16> &matrix,
                         std::array<float, 16> &inverse) {
    if (!affineModelView(matrix)) {
        return false;
    }

    const float a00 = matrix[0];
    const float a01 = matrix[4];
    const float a02 = matrix[8];
    const float a10 = matrix[1];
    const float a11 = matrix[5];
    const float a12 = matrix[9];
    const float a20 = matrix[2];
    const float a21 = matrix[6];
    const float a22 = matrix[10];

    const float c00 = a11 * a22 - a12 * a21;
    const float c01 = a12 * a20 - a10 * a22;
    const float c02 = a10 * a21 - a11 * a20;
    const float c10 = a02 * a21 - a01 * a22;
    const float c11 = a00 * a22 - a02 * a20;
    const float c12 = a01 * a20 - a00 * a21;
    const float c20 = a01 * a12 - a02 * a11;
    const float c21 = a02 * a10 - a00 * a12;
    const float c22 = a00 * a11 - a01 * a10;
    const float determinant = a00 * c00 + a01 * c01 + a02 * c02;
    if (!std::isfinite(determinant) || std::abs(determinant) < 1.0e-8F) {
        return false;
    }

    const float scale = 1.0F / determinant;
    inverse = {
        c00 * scale, c01 * scale, c02 * scale, 0.0F,
        c10 * scale, c11 * scale, c12 * scale, 0.0F,
        c20 * scale, c21 * scale, c22 * scale, 0.0F,
        0.0F, 0.0F, 0.0F, 1.0F,
    };
    const float translation[3] = {matrix[12], matrix[13], matrix[14]};
    for (std::size_t row = 0; row < 3; ++row) {
        inverse[12 + row] = -(
            inverse[row] * translation[0] +
            inverse[4 + row] * translation[1] +
            inverse[8 + row] * translation[2]);
    }
    return finiteMatrix(inverse);
}

bool matricesNear(const std::array<float, 16> &left,
                  const std::array<float, 16> &right,
                  float epsilon = 1.0e-2F) {
    for (std::size_t index = 0; index < left.size(); ++index) {
        // Scene space is anchored around the first camera, so translations
        // stay local enough for an absolute tolerance. A relative tolerance
        // would incorrectly accept whole-block relocation at larger offsets.
        if (std::abs(left[index] - right[index]) > epsilon) {
            return false;
        }
    }
    return true;
}

struct LinearTransformKey final {
    std::array<std::int32_t, 9> values{};

    bool operator==(const LinearTransformKey &) const = default;
};

struct LinearTransformKeyHash final {
    std::size_t operator()(const LinearTransformKey &key) const {
        std::size_t seed = 0;
        for (std::int32_t value : key.values) {
            hashCombine(seed, value);
        }
        return seed;
    }
};

bool linearTransformKey(const std::array<float, 16> &matrix,
                        LinearTransformKey &key) {
    constexpr double quantization = 8192.0;
    constexpr std::size_t indices[9] = {0, 1, 2, 4, 5, 6, 8, 9, 10};
    for (std::size_t output = 0; output < key.values.size(); ++output) {
        const double quantized = std::round(
            static_cast<double>(matrix[indices[output]]) * quantization);
        if (!std::isfinite(quantized) ||
            quantized < std::numeric_limits<std::int32_t>::min() ||
            quantized > std::numeric_limits<std::int32_t>::max()) {
            return false;
        }
        key.values[output] = static_cast<std::int32_t>(quantized);
    }
    return true;
}

struct GeometryKey final {
    std::int32_t vertexBufferId = -1;
    std::int32_t indexBufferId = -1;
    std::int32_t vertexFormatType = -1;
    std::size_t vertexStride = 0;
    std::int32_t drawMode = -1;
    std::int32_t indexCount = 0;
    std::int32_t indexType = -1;
    std::int32_t firstIndex = 0;
    std::int32_t firstVertex = 0;
    std::int32_t textureId = -1;

    // Transparent terrain re-sorts its index buffer while retaining the same
    // vertex buffer. The vertex ID is the stable materialization identity; an
    // index-only reorder does not change the triangle set or its BLAS.
    bool operator==(const GeometryKey &other) const {
        return vertexBufferId == other.vertexBufferId;
    }
};

struct GeometryKeyHash final {
    std::size_t operator()(const GeometryKey &key) const {
        std::size_t seed = 0;
        hashCombine(seed, key.vertexBufferId);
        return seed;
    }
};

bool sameGeometryLayout(const GeometryKey &cached, const GeometryKey &draw) {
    return cached.vertexFormatType == draw.vertexFormatType &&
           cached.vertexStride == draw.vertexStride &&
           cached.drawMode == draw.drawMode &&
           cached.indexCount == draw.indexCount &&
           cached.indexType == draw.indexType &&
           cached.firstIndex == draw.firstIndex &&
           cached.firstVertex == draw.firstVertex;
}

enum class GeometryState : std::uint8_t {
    PendingExpansion,
    PendingBuild,
    Scheduled,
    Ready,
    Rejected,
};

struct Geometry final {
    GeometryKey key;
    std::uint64_t serial = 0;
    id<MTLBuffer> sourceVertices = nil;
    id<MTLBuffer> sourceIndices = nil;
    std::size_t sourceVertexBytes = 0;
    std::size_t sourceIndexBytes = 0;
    std::size_t canonicalVertexOffset = 0;
    std::size_t canonicalVertexCount = 0;
    std::int32_t textureId = -1;
    GeometryState state = GeometryState::PendingExpansion;
    id<MTLAccelerationStructure> bottomLevel = nil;
    bool terrainConfirmed = false;
    std::uint64_t transformEpoch = 0;
    std::uint64_t lastVisibleFrame = 0;
    std::array<float, 16> localToScene{};
    std::array<float, 12> normalToScene{};
    std::uint32_t metadataFlags = kRTInstanceFlagOpaque;
    std::uint32_t instanceMask = kWorldInstanceMask;
    std::string rejectionReason;
};

struct ObservedInstance final {
    Geometry *geometry = nullptr;
    std::array<float, 16> modelView{};
    std::array<float, 12> normalToView{};
};

struct ExpandedGeometry final {
    Geometry *geometry = nullptr;
    std::vector<RTVertex> vertices;
    std::size_t canonicalOffset = 0;
    bool reusedCanonicalRange = false;
};

struct CanonicalFreeRange final {
    std::size_t offset = 0;
    std::size_t count = 0;
    std::uint64_t availableAfterFrame = 0;
};

struct BottomLevelBuild final {
    Geometry *geometry = nullptr;
    MTLPrimitiveAccelerationStructureDescriptor *descriptor = nil;
    id<MTLAccelerationStructure> accelerationStructure = nil;
    id<MTLBuffer> scratchBuffer = nil;
};

struct DynamicObservation final {
    DynamicEntityDrawInput draw;
    id<MTLBuffer> sourceVertices = nil;
    id<MTLBuffer> sourceIndices = nil;
    std::size_t sourceVertexBytes = 0;
    std::size_t sourceIndexBytes = 0;
};

struct DynamicBottomLevelBuild final {
    bool refit = false;
    MTLPrimitiveAccelerationStructureDescriptor *descriptor = nil;
    id<MTLAccelerationStructure> accelerationStructure = nil;
    id<MTLBuffer> scratchBuffer = nil;
};

struct DynamicFrameResources final {
    std::vector<RTVertex> stagingVertices;
    id<MTLBuffer> canonicalVertices = nil;
    std::size_t canonicalVertexCapacity = 0;
    id<MTLBuffer> scratchBuffer = nil;
    std::size_t scratchByteCapacity = 0;
};

struct ProxyBox final {
    std::array<float, 3> center{};
    std::array<float, 3> halfExtent{};
    std::array<float, 3> pivot{};
    float pitchRadians = 0.0F;
    float yawRadians = 0.0F;
};

std::array<float, 3> rotatePlayerVector(
    const std::array<float, 3> &value, float yaw) {
    const float sine = std::sin(yaw);
    const float cosine = std::cos(yaw);
    return {
        cosine * value[0] - sine * value[2],
        value[1],
        sine * value[0] + cosine * value[2],
    };
}

std::array<float, 3> rotateProxyPartVector(
    const std::array<float, 3> &value, float pitch, float yaw) {
    const float pitchSine = std::sin(pitch);
    const float pitchCosine = std::cos(pitch);
    const std::array<float, 3> pitched{
        value[0],
        pitchCosine * value[1] - pitchSine * value[2],
        pitchSine * value[1] + pitchCosine * value[2],
    };
    return rotatePlayerVector(pitched, yaw);
}

std::array<float, 3> transformLinearVector(
    const std::array<float, 12> &matrix,
    const std::array<float, 3> &value) {
    return {
        matrix[0] * value[0] + matrix[4] * value[1] + matrix[8] * value[2],
        matrix[1] * value[0] + matrix[5] * value[1] + matrix[9] * value[2],
        matrix[2] * value[0] + matrix[6] * value[1] + matrix[10] * value[2],
    };
}

bool deriveCameraAnchoredView(
    const std::array<float, 12> &anchorWorldToScene,
    const std::array<float, 16> &currentModelView,
    const std::array<double, 3> &anchorWorldCamera,
    const std::array<double, 3> &currentWorldCamera,
    std::array<float, 16> &viewToScene) {
    std::array<float, 16> currentWorldToView = currentModelView;
    currentWorldToView[12] = 0.0F;
    currentWorldToView[13] = 0.0F;
    currentWorldToView[14] = 0.0F;
    std::array<float, 16> currentViewToWorld{};
    if (!inverseAffineMatrix(currentWorldToView, currentViewToWorld)) {
        return false;
    }

    std::array<float, 16> anchorLinear = identityMatrix();
    anchorLinear[0] = anchorWorldToScene[0];
    anchorLinear[1] = anchorWorldToScene[1];
    anchorLinear[2] = anchorWorldToScene[2];
    anchorLinear[4] = anchorWorldToScene[4];
    anchorLinear[5] = anchorWorldToScene[5];
    anchorLinear[6] = anchorWorldToScene[6];
    anchorLinear[8] = anchorWorldToScene[8];
    anchorLinear[9] = anchorWorldToScene[9];
    anchorLinear[10] = anchorWorldToScene[10];
    viewToScene = multiplyMatrices(anchorLinear, currentViewToWorld);

    std::array<float, 3> cameraDelta{};
    for (std::size_t axis = 0; axis < cameraDelta.size(); ++axis) {
        const double delta = currentWorldCamera[axis] - anchorWorldCamera[axis];
        if (!std::isfinite(delta) || std::abs(delta) > kMaximumAnchorDistance) {
            return false;
        }
        cameraDelta[axis] = static_cast<float>(delta);
    }
    const std::array<float, 3> translation = transformLinearVector(
        anchorWorldToScene, cameraDelta);
    viewToScene[12] = translation[0];
    viewToScene[13] = translation[1];
    viewToScene[14] = translation[2];
    viewToScene[15] = 1.0F;
    return finiteMatrix(viewToScene) && affineModelView(viewToScene);
}

bool appendProxyBox(const ProxyBox &box,
                    const LocalPlayerShadowProxyInput &proxy,
                    const std::array<float, 3> &sceneCamera,
                    const std::array<float, 12> &worldToScene,
                    std::vector<RTVertex> &vertices) {
    constexpr std::array<std::array<int, 3>, 8> cornerSigns{{
        {-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
        {-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1},
    }};
    constexpr std::array<std::array<std::uint8_t, 3>, kTrianglesPerBox>
        triangleCorners{{
            {0, 3, 2}, {0, 2, 1}, {4, 5, 6}, {4, 6, 7},
            {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5},
            {0, 1, 5}, {0, 5, 4}, {3, 7, 6}, {3, 6, 2},
        }};
    constexpr std::array<std::array<float, 3>, 6> faceNormals{{
        {0.0F, 0.0F, -1.0F}, {0.0F, 0.0F, 1.0F},
        {-1.0F, 0.0F, 0.0F}, {1.0F, 0.0F, 0.0F},
        {0.0F, -1.0F, 0.0F}, {0.0F, 1.0F, 0.0F},
    }};

    std::array<std::array<float, 3>, 8> sceneCorners{};
    for (std::size_t index = 0; index < sceneCorners.size(); ++index) {
        std::array<float, 3> local{
            box.center[0] + box.halfExtent[0] * cornerSigns[index][0],
            box.center[1] + box.halfExtent[1] * cornerSigns[index][1],
            box.center[2] + box.halfExtent[2] * cornerSigns[index][2],
        };
        const std::array<float, 3> pivotRelative{
            local[0] - box.pivot[0],
            local[1] - box.pivot[1],
            local[2] - box.pivot[2],
        };
        const std::array<float, 3> articulated = rotateProxyPartVector(
            pivotRelative, box.pitchRadians, box.yawRadians);
        local = {
            box.pivot[0] + articulated[0],
            box.pivot[1] + articulated[1],
            box.pivot[2] + articulated[2],
        };
        const std::array<float, 3> rotated = rotatePlayerVector(
            local, proxy.bodyYawRadians);
        const std::array<float, 3> cameraRelativeWorld{
            proxy.cameraRelativePosition[0] + rotated[0],
            proxy.cameraRelativePosition[1] + rotated[1],
            proxy.cameraRelativePosition[2] + rotated[2],
        };
        const std::array<float, 3> sceneOffset = transformLinearVector(
            worldToScene, cameraRelativeWorld);
        sceneCorners[index] = {
            sceneCamera[0] + sceneOffset[0],
            sceneCamera[1] + sceneOffset[1],
            sceneCamera[2] + sceneOffset[2],
        };
    }

    const std::size_t firstVertex = vertices.size();
    try {
        vertices.resize(firstVertex + kVerticesPerBox);
    } catch (const std::bad_alloc &) {
        return false;
    }
    for (std::size_t triangle = 0; triangle < triangleCorners.size(); ++triangle) {
        std::array<float, 3> normal = transformLinearVector(
            worldToScene,
            rotatePlayerVector(
                rotateProxyPartVector(faceNormals[triangle / 2U],
                                      box.pitchRadians, box.yawRadians),
                proxy.bodyYawRadians));
        const float lengthSquared = normal[0] * normal[0] +
                                    normal[1] * normal[1] +
                                    normal[2] * normal[2];
        if (!std::isfinite(lengthSquared) || lengthSquared <= 1.0e-12F) {
            vertices.resize(firstVertex);
            return false;
        }
        const float inverseLength = 1.0F / std::sqrt(lengthSquared);
        for (std::size_t corner = 0; corner < 3; ++corner) {
            RTVertex vertex{};
            const std::array<float, 3> &position =
                sceneCorners[triangleCorners[triangle][corner]];
            std::copy(position.begin(), position.end(), vertex.position);
            for (std::size_t axis = 0; axis < 3; ++axis) {
                vertex.normal[axis] = static_cast<std::int8_t>(std::lround(
                    std::clamp(normal[axis] * inverseLength, -1.0F, 1.0F) *
                    127.0F));
            }
            vertex.normal[3] = 0;
            vertex.uv[0] = 0.0F;
            vertex.uv[1] = 0.0F;
            vertex.color[0] = 160;
            vertex.color[1] = 160;
            vertex.color[2] = 160;
            vertex.color[3] = 255;
            vertex.textureId = static_cast<std::int32_t>(kProxyTextureId);
            vertices[firstVertex + triangle * 3U + corner] = vertex;
        }
    }
    return true;
}

bool appendLocalPlayerShadowProxy(
    const LocalPlayerShadowProxyInput &proxy,
    const std::array<float, 16> &viewToScene,
    const std::array<float, 12> &worldToScene,
    std::vector<RTVertex> &vertices) {
    std::array<ProxyBox, kLocalPlayerBoxCount> boxes{};
    if (proxy.pose == 2U) {
        boxes = {{
            {{0.0F, 0.30F, 0.72F}, {0.25F, 0.25F, 0.25F}},
            {{0.0F, 0.30F, 0.15F}, {0.25F, 0.125F, 0.36F}},
            {{-0.375F, 0.30F, 0.15F}, {0.125F, 0.125F, 0.36F}},
            {{0.375F, 0.30F, 0.15F}, {0.125F, 0.125F, 0.36F}},
            {{-0.125F, 0.30F, -0.55F}, {0.125F, 0.125F, 0.36F}},
            {{0.125F, 0.30F, -0.55F}, {0.125F, 0.125F, 0.36F}},
        }};
    } else if (proxy.pose == 1U) {
        boxes = {{
            {{0.0F, 1.34F, 0.15F}, {0.25F, 0.25F, 0.25F}},
            {{0.0F, 0.93F, 0.08F}, {0.25F, 0.30F, 0.125F}},
            {{-0.375F, 0.93F, 0.08F}, {0.125F, 0.30F, 0.125F}},
            {{0.375F, 0.93F, 0.08F}, {0.125F, 0.30F, 0.125F}},
            {{-0.125F, 0.32F, 0.0F}, {0.125F, 0.32F, 0.125F}},
            {{0.125F, 0.32F, 0.0F}, {0.125F, 0.32F, 0.125F}},
        }};
    } else {
        boxes = {{
            {{0.0F, 1.70F, 0.0F}, {0.25F, 0.25F, 0.25F}},
            {{0.0F, 1.12F, 0.0F}, {0.25F, 0.375F, 0.125F}},
            {{-0.375F, 1.10F, 0.0F}, {0.125F, 0.375F, 0.125F}},
            {{0.375F, 1.10F, 0.0F}, {0.125F, 0.375F, 0.125F}},
            {{-0.125F, 0.375F, 0.0F}, {0.125F, 0.375F, 0.125F}},
            {{0.125F, 0.375F, 0.0F}, {0.125F, 0.375F, 0.125F}},
        }};
    }

    constexpr float pi = 3.14159265358979323846F;
    const float limbAmplitude = std::clamp(proxy.limbAmplitude, 0.0F, 1.0F) *
        (proxy.pose == 2U ? 0.55F : 1.0F);
    const float walkPhase = proxy.limbPhase * 0.6662F;
    float leftArmPitch = std::cos(walkPhase) * limbAmplitude;
    float rightArmPitch = std::cos(walkPhase + pi) * limbAmplitude;
    const float leftLegPitch = std::cos(walkPhase + pi) *
        (1.35F * limbAmplitude);
    const float rightLegPitch = std::cos(walkPhase) *
        (1.35F * limbAmplitude);
    const float handSwing = std::clamp(proxy.handSwingProgress, 0.0F, 1.0F);
    if (handSwing > 0.0F) {
        const float attackArc = std::sin(std::sqrt(handSwing) * 2.0F * pi) *
            0.65F + std::sin(handSwing * pi) * 0.45F;
        rightArmPitch -= attackArc;
    }

    if (proxy.pose == 2U) {
        boxes[0].pivot = {0.0F, 0.30F, 0.47F};
        boxes[2].pivot = {-0.375F, 0.30F, 0.51F};
        boxes[3].pivot = {0.375F, 0.30F, 0.51F};
        boxes[4].pivot = {-0.125F, 0.30F, -0.19F};
        boxes[5].pivot = {0.125F, 0.30F, -0.19F};
    } else if (proxy.pose == 1U) {
        boxes[0].pivot = {0.0F, 1.09F, 0.12F};
        boxes[2].pivot = {-0.375F, 1.23F, 0.08F};
        boxes[3].pivot = {0.375F, 1.23F, 0.08F};
        boxes[4].pivot = {-0.125F, 0.64F, 0.0F};
        boxes[5].pivot = {0.125F, 0.64F, 0.0F};
    } else {
        boxes[0].pivot = {0.0F, 1.45F, 0.0F};
        boxes[2].pivot = {-0.375F, 1.475F, 0.0F};
        boxes[3].pivot = {0.375F, 1.475F, 0.0F};
        boxes[4].pivot = {-0.125F, 0.75F, 0.0F};
        boxes[5].pivot = {0.125F, 0.75F, 0.0F};
    }
    boxes[0].pitchRadians = proxy.headPitchRadians;
    boxes[0].yawRadians = proxy.headYawRadians;
    boxes[2].pitchRadians = leftArmPitch;
    boxes[3].pitchRadians = rightArmPitch;
    boxes[4].pitchRadians = leftLegPitch;
    boxes[5].pitchRadians = rightLegPitch;

    const std::size_t firstVertex = vertices.size();
    try {
        vertices.reserve(firstVertex + kLocalPlayerProxyVertexCount);
    } catch (const std::bad_alloc &) {
        return false;
    }
    const std::array<float, 3> sceneCamera{
        viewToScene[12], viewToScene[13], viewToScene[14]};
    for (const ProxyBox &box : boxes) {
        if (!appendProxyBox(box, proxy, sceneCamera, worldToScene, vertices)) {
            vertices.resize(firstVertex);
            return false;
        }
    }
    return vertices.size() - firstVertex == kLocalPlayerProxyVertexCount;
}

struct ActiveInstance final {
    Geometry *geometry = nullptr;
    std::array<float, 16> localToScene{};
    std::array<float, 12> normalToScene{};
};

struct TopLevelUpdate final {
    bool rebuild = false;
    MTLInstanceAccelerationStructureDescriptor *descriptor = nil;
    id<MTLAccelerationStructure> accelerationStructure = nil;
    id<MTLBuffer> scratchBuffer = nil;
    id<MTLBuffer> instanceDescriptorBuffer = nil;
    id<MTLBuffer> instanceMetadataBuffer = nil;
    std::vector<std::uint64_t> serials;
    std::vector<std::array<float, 16>> transforms;
    std::vector<std::int32_t> textureIds;
    std::vector<std::uint32_t> metadataFlags;
    std::vector<id<MTLAccelerationStructure>> bottomLevels;
};

std::size_t deriveViewToScene(
    const std::unordered_map<std::uint64_t, ObservedInstance> &observedInstances,
    const std::unordered_set<std::uint64_t> &eligibleSerials,
    std::uint64_t sceneEpoch,
    std::array<float, 16> &bestViewToScene) {
    constexpr std::size_t kMaxCandidates = 8;
    constexpr std::size_t kMaxTests = 64;
    std::size_t candidateCount = 0;
    std::size_t bestMatches = 0;
    std::size_t bestTests = 0;

    for (const auto &[serial, candidateObserved] : observedInstances) {
        const Geometry &candidateGeometry = *candidateObserved.geometry;
        if (!eligibleSerials.contains(serial) ||
            candidateGeometry.transformEpoch != sceneEpoch ||
            candidateGeometry.state != GeometryState::Ready) {
            continue;
        }
        if (candidateCount++ >= kMaxCandidates) {
            break;
        }

        std::array<float, 16> currentViewFromLocal{};
        if (!inverseAffineMatrix(candidateObserved.modelView,
                                 currentViewFromLocal)) {
            continue;
        }
        const std::array<float, 16> candidateViewToScene = multiplyMatrices(
            candidateGeometry.localToScene, currentViewFromLocal);
        if (!finiteMatrix(candidateViewToScene) ||
            !affineModelView(candidateViewToScene)) {
            continue;
        }

        std::size_t matches = 0;
        std::size_t tests = 0;
        for (const auto &[testSerial, testObserved] : observedInstances) {
            const Geometry &testGeometry = *testObserved.geometry;
            if (!eligibleSerials.contains(testSerial) ||
                testGeometry.transformEpoch != sceneEpoch ||
                testGeometry.state != GeometryState::Ready) {
                continue;
            }
            if (tests >= kMaxTests) {
                break;
            }
            ++tests;
            const std::array<float, 16> predicted = multiplyMatrices(
                candidateViewToScene, testObserved.modelView);
            if (matricesNear(predicted, testGeometry.localToScene)) {
                ++matches;
            }
        }
        if (matches > bestMatches) {
            bestMatches = matches;
            bestTests = tests;
            bestViewToScene = candidateViewToScene;
        }
    }

    if (bestTests == 0 || bestMatches * 4 < bestTests * 3) {
        return 0;
    }
    return bestMatches;
}

bool geometryBuffersResident(const Geometry &geometry) {
    BufferManager &buffers = BufferManager::shared();
    id<MTLBuffer> vertices = buffers.buffer(geometry.key.vertexBufferId);
    id<MTLBuffer> indices = buffers.buffer(geometry.key.indexBufferId);
    if (vertices == nil || indices == nil ||
        buffers.size(geometry.key.vertexBufferId) != geometry.sourceVertexBytes ||
        buffers.size(geometry.key.indexBufferId) != geometry.sourceIndexBytes) {
        return false;
    }
    return (buffers.usageFlags(geometry.key.vertexBufferId) &
            kPersistentVertexUsage) != 0 &&
           (buffers.usageFlags(geometry.key.indexBufferId) &
            kPersistentIndexUsage) != 0;
}

bool usesProgrammableIntersection(std::uint32_t flags) {
    return (flags & (kRTInstanceFlagTranslucent |
                     kRTInstanceFlagAlphaTest |
                     kRTInstanceFlagDynamicVertexBuffer)) != 0U;
}

bool indexElementSize(std::int32_t indexType, std::size_t &size) {
    switch (indexType) {
    case 0:
        size = sizeof(std::uint16_t);
        return true;
    case 1:
        size = sizeof(std::uint32_t);
        return true;
    default:
        return false;
    }
}

bool validateSourceRanges(const WorldDrawInput &draw,
                          std::size_t vertexBufferSize,
                          std::size_t indexBufferSize,
                          std::string &error) {
    std::size_t indexSize = 0;
    if (!indexElementSize(draw.indexType, indexSize)) {
        error = "ray-tracing terrain index type must be uint16 or uint32";
        return false;
    }

    std::size_t indexOffset = 0;
    std::size_t indexBytes = 0;
    if (!checkedMultiply(static_cast<std::size_t>(draw.firstIndex), indexSize,
                         indexOffset) ||
        !checkedMultiply(static_cast<std::size_t>(draw.indexCount), indexSize,
                         indexBytes)) {
        error = "ray-tracing terrain index range overflows size_t";
        return false;
    }
    if (indexOffset > indexBufferSize ||
        indexBytes > indexBufferSize - indexOffset) {
        error = "ray-tracing terrain index range exceeds its shared buffer";
        return false;
    }
    if (vertexBufferSize < draw.vertexStride) {
        error = "ray-tracing terrain vertex buffer contains no complete vertex";
        return false;
    }
    return true;
}

bool expandGeometry(Geometry &geometry, std::vector<RTVertex> &vertices,
                    std::string &error) {
    const void *vertexContents = geometry.sourceVertices.contents;
    const void *indexContents = geometry.sourceIndices.contents;
    if (vertexContents == nullptr || indexContents == nullptr) {
        error = "shared terrain buffer lost CPU visibility before RT expansion";
        return false;
    }

    std::size_t indexSize = 0;
    if (!indexElementSize(geometry.key.indexType, indexSize)) {
        error = "terrain geometry has an unsupported index type";
        return false;
    }

    const std::size_t count = static_cast<std::size_t>(geometry.key.indexCount);
    const std::size_t firstIndex = static_cast<std::size_t>(geometry.key.firstIndex);
    std::size_t indexOffset = 0;
    if (!checkedMultiply(firstIndex, indexSize, indexOffset)) {
        error = "terrain geometry index offset overflows size_t";
        return false;
    }

    try {
        vertices.resize(count);
    } catch (const std::bad_alloc &) {
        error = "unable to allocate canonical terrain expansion";
        return false;
    }

    const auto *sourceVertices = static_cast<const std::byte *>(vertexContents);
    const auto *sourceIndices = static_cast<const std::byte *>(indexContents);
    for (std::size_t outputIndex = 0; outputIndex < count; ++outputIndex) {
        std::uint32_t sourceIndex = 0;
        if (indexSize == sizeof(std::uint16_t)) {
            std::uint16_t value = 0;
            std::memcpy(&value, sourceIndices + indexOffset + outputIndex * indexSize,
                        sizeof(value));
            sourceIndex = value;
        } else {
            std::memcpy(&sourceIndex,
                        sourceIndices + indexOffset + outputIndex * indexSize,
                        sizeof(sourceIndex));
        }

        const std::int64_t adjustedIndex = static_cast<std::int64_t>(sourceIndex) +
            static_cast<std::int64_t>(geometry.key.firstVertex);
        if (adjustedIndex < 0) {
            error = "terrain geometry base vertex produces a negative vertex index";
            return false;
        }

        std::size_t sourceOffset = 0;
        if (!checkedMultiply(static_cast<std::size_t>(adjustedIndex),
                             geometry.key.vertexStride, sourceOffset) ||
            sourceOffset > geometry.sourceVertexBytes ||
            geometry.key.vertexStride > geometry.sourceVertexBytes - sourceOffset) {
            error = "terrain geometry references a vertex outside its shared buffer";
            return false;
        }

        const std::byte *source = sourceVertices + sourceOffset;
        RTVertex vertex{};
        std::memcpy(vertex.position, source, sizeof(vertex.position));
        std::memcpy(vertex.color, source + 12, sizeof(vertex.color));
        std::memcpy(vertex.uv, source + 16, sizeof(vertex.uv));
        std::memcpy(vertex.normal, source + 28, 3);
        vertex.normal[3] = 0;
        vertex.textureId = geometry.textureId;
        if (!std::all_of(std::begin(vertex.position), std::end(vertex.position),
                         [](float value) { return std::isfinite(value); }) ||
            !std::all_of(std::begin(vertex.uv), std::end(vertex.uv),
                         [](float value) { return std::isfinite(value); })) {
            error = "terrain geometry contains a non-finite position or UV";
            return false;
        }
        vertices[outputIndex] = vertex;
    }
    return true;
}

bool validateDynamicSourceRanges(const DynamicEntityDrawInput &draw,
                                 std::size_t vertexBufferSize,
                                 std::size_t indexBufferSize,
                                 std::string &error) {
    std::size_t indexSize = 0;
    if (!indexElementSize(draw.indexType, indexSize)) {
        error = "dynamic entity index type must be uint16 or uint32";
        return false;
    }

    std::size_t indexOffset = 0;
    std::size_t indexBytes = 0;
    if (!checkedMultiply(static_cast<std::size_t>(draw.firstIndex), indexSize,
                         indexOffset) ||
        !checkedMultiply(static_cast<std::size_t>(draw.indexCount), indexSize,
                         indexBytes)) {
        error = "dynamic entity index range overflows size_t";
        return false;
    }
    if (indexOffset > indexBufferSize ||
        indexBytes > indexBufferSize - indexOffset) {
        error = "dynamic entity index range exceeds its shared buffer";
        return false;
    }
    if (vertexBufferSize < draw.vertexStride) {
        error = "dynamic entity vertex buffer contains no complete vertex";
        return false;
    }
    return true;
}

bool expandDynamicEntity(const DynamicObservation &observation,
                         const std::array<float, 16> &localToScene,
                         std::vector<RTVertex> &vertices,
                         std::string &error) {
    const void *vertexContents = observation.sourceVertices.contents;
    const void *indexContents = observation.sourceIndices.contents;
    if (vertexContents == nullptr || indexContents == nullptr) {
        error = "transient entity buffer lost CPU visibility before RT expansion";
        return false;
    }

    std::array<float, 12> normalToScene{};
    if (!normalMatrixForModelView(localToScene, normalToScene)) {
        error = "dynamic entity has a singular local-to-scene transform";
        return false;
    }

    std::size_t indexSize = 0;
    if (!indexElementSize(observation.draw.indexType, indexSize)) {
        error = "dynamic entity has an unsupported index type";
        return false;
    }
    const std::size_t count = static_cast<std::size_t>(observation.draw.indexCount);
    std::size_t indexOffset = 0;
    if (!checkedMultiply(static_cast<std::size_t>(observation.draw.firstIndex),
                         indexSize, indexOffset)) {
        error = "dynamic entity index offset overflows size_t";
        return false;
    }

    const std::size_t previousVertexCount = vertices.size();
    std::size_t requiredVertexCount = 0;
    if (!checkedAdd(previousVertexCount, count, requiredVertexCount)) {
        error = "dynamic canonical vertex count overflows size_t";
        return false;
    }
    try {
        vertices.resize(requiredVertexCount);
    } catch (const std::bad_alloc &) {
        error = "unable to allocate dynamic canonical entity vertices";
        return false;
    }

    const auto *sourceVertices = static_cast<const std::byte *>(vertexContents);
    const auto *sourceIndices = static_cast<const std::byte *>(indexContents);
    for (std::size_t outputIndex = 0; outputIndex < count; ++outputIndex) {
        std::uint32_t sourceIndex = 0;
        if (indexSize == sizeof(std::uint16_t)) {
            std::uint16_t value = 0;
            std::memcpy(&value, sourceIndices + indexOffset + outputIndex * indexSize,
                        sizeof(value));
            sourceIndex = value;
        } else {
            std::memcpy(&sourceIndex,
                        sourceIndices + indexOffset + outputIndex * indexSize,
                        sizeof(sourceIndex));
        }

        const std::int64_t adjustedIndex = static_cast<std::int64_t>(sourceIndex) +
            static_cast<std::int64_t>(observation.draw.firstVertex);
        if (adjustedIndex < 0) {
            vertices.resize(previousVertexCount);
            error = "dynamic entity base vertex produces a negative vertex index";
            return false;
        }

        std::size_t sourceOffset = 0;
        if (!checkedMultiply(static_cast<std::size_t>(adjustedIndex),
                             observation.draw.vertexStride, sourceOffset) ||
            sourceOffset > observation.sourceVertexBytes ||
            observation.draw.vertexStride >
                observation.sourceVertexBytes - sourceOffset) {
            vertices.resize(previousVertexCount);
            error = "dynamic entity references a vertex outside its shared buffer";
            return false;
        }

        const std::byte *source = sourceVertices + sourceOffset;
        float localPosition[3]{};
        std::int8_t localNormal[3]{};
        RTVertex vertex{};
        std::memcpy(localPosition, source, sizeof(localPosition));
        std::memcpy(vertex.color, source + 12, sizeof(vertex.color));
        std::memcpy(vertex.uv, source + 16, sizeof(vertex.uv));
        std::memcpy(localNormal, source + 32, sizeof(localNormal));
        if (!transformPosition(localToScene, localPosition, vertex.position) ||
            !transformPackedNormal(normalToScene, localNormal, vertex.normal) ||
            !std::all_of(std::begin(vertex.uv), std::end(vertex.uv),
                         [](float value) { return std::isfinite(value); })) {
            vertices.resize(previousVertexCount);
            error = "dynamic entity contains a non-finite position, normal, or UV";
            return false;
        }
        std::uint32_t encodedTextureId =
            static_cast<std::uint32_t>(observation.draw.textureId);
        if ((observation.draw.materialFlags & kRTInstanceFlagAlphaTest) != 0U) {
            encodedTextureId |= kDynamicTextureAlphaTestBit;
        }
        if ((observation.draw.materialFlags & kRTInstanceFlagTranslucent) != 0U) {
            encodedTextureId |= kDynamicTextureTranslucentBit;
        }
        vertex.textureId = std::bit_cast<std::int32_t>(encodedTextureId);
        vertices[previousVertexCount + outputIndex] = vertex;
    }
    return true;
}

} // namespace

struct AccelStructManager::Impl final {
    mutable std::mutex mutex;
    id<MTLDevice> device = nil;
    bool frameOpen = false;
    std::uint64_t frameOrdinal = 0;
    std::uint64_t nextGeometrySerial = 1;
    std::unordered_map<GeometryKey, std::unique_ptr<Geometry>, GeometryKeyHash>
        geometries;
    std::unordered_map<std::uint64_t, ObservedInstance> observedInstances;
    std::unordered_set<std::uint64_t> excludedThisFrame;
    std::vector<DynamicObservation> dynamicObservations;
    std::size_t observedDynamicDrawCount = 0;
    std::size_t rejectedDynamicDrawCount = 0;
    std::string dynamicObservationDiagnostic;
    LocalPlayerShadowProxyInput localPlayerShadowProxy{};
    bool observedProjectionValid = false;
    std::array<float, 16> observedProjection{};

    id<MTLBuffer> canonicalVertexBuffer = nil;
    std::size_t canonicalVertexCount = 0;
    std::size_t canonicalVertexCapacity = 0;
    std::vector<CanonicalFreeRange> canonicalFreeRanges;
    id<MTLBuffer> dynamicCanonicalVertexBuffer = nil;
    std::size_t dynamicCanonicalVertexCount = 0;
    std::array<DynamicFrameResources, kDynamicFramesInFlight> dynamicFrames{};
    std::size_t dynamicFrameIndex = kDynamicFramesInFlight - 1U;
    Geometry dynamicGeometry;
    Geometry localPlayerGeometry;
    bool dynamicTLASBoundsValid = false;
    std::array<float, 3> dynamicTLASBoundsMinimum{};
    std::array<float, 3> dynamicTLASBoundsMaximum{};
    std::size_t dynamicTLASVertexCount = 0;

    id<MTLAccelerationStructure> topLevel = nil;
    id<MTLBuffer> instanceDescriptorBuffer = nil;
    id<MTLBuffer> instanceMetadataBuffer = nil;
    std::vector<std::uint64_t> activeSerials;
    std::vector<std::array<float, 16>> activeTransforms;
    std::vector<std::int32_t> activeTextureIds;
    std::vector<std::uint32_t> activeMetadataFlags;
    std::vector<id<MTLAccelerationStructure>> activeBottomLevels;
    std::array<float, 16> projection{};
    bool sceneAnchorValid = false;
    std::uint64_t sceneEpoch = 0;
    std::array<float, 16> viewToScene = identityMatrix();
    std::array<float, 12> worldToSceneLinear = paddedLinearColumns(
        identityMatrix());
    std::array<double, 3> anchorWorldCamera{};
    bool anchorWorldCameraValid = false;
    std::uint64_t generation = 0;

    Impl() {
        dynamicGeometry.serial = kDynamicGeometrySerial;
        dynamicGeometry.localToScene = identityMatrix();
        dynamicGeometry.normalToScene = paddedLinearColumns(identityMatrix());
        dynamicGeometry.metadataFlags = kRTInstanceFlagDynamicVertexBuffer;
        dynamicGeometry.instanceMask = kWorldInstanceMask;
        localPlayerGeometry.serial = kLocalPlayerGeometrySerial;
        localPlayerGeometry.localToScene = identityMatrix();
        localPlayerGeometry.normalToScene = paddedLinearColumns(identityMatrix());
        localPlayerGeometry.metadataFlags = kRTInstanceFlagDynamicVertexBuffer;
        localPlayerGeometry.instanceMask = kLocalPlayerShadowInstanceMask;
    }

    void resetScene() {
        frameOpen = false;
        nextGeometrySerial = 1;
        geometries.clear();
        observedInstances.clear();
        excludedThisFrame.clear();
        dynamicObservations.clear();
        observedDynamicDrawCount = 0;
        rejectedDynamicDrawCount = 0;
        dynamicObservationDiagnostic.clear();
        localPlayerShadowProxy = {};
        observedProjectionValid = false;
        observedProjection.fill(0.0F);
        canonicalVertexBuffer = nil;
        canonicalVertexCount = 0;
        canonicalVertexCapacity = 0;
        canonicalFreeRanges.clear();
        dynamicCanonicalVertexBuffer = nil;
        dynamicCanonicalVertexCount = 0;
        dynamicFrames = {};
        dynamicFrameIndex = kDynamicFramesInFlight - 1U;
        dynamicGeometry = Geometry{};
        dynamicGeometry.serial = kDynamicGeometrySerial;
        dynamicGeometry.localToScene = identityMatrix();
        dynamicGeometry.normalToScene = paddedLinearColumns(identityMatrix());
        dynamicGeometry.metadataFlags = kRTInstanceFlagDynamicVertexBuffer;
        dynamicGeometry.instanceMask = kWorldInstanceMask;
        localPlayerGeometry = Geometry{};
        localPlayerGeometry.serial = kLocalPlayerGeometrySerial;
        localPlayerGeometry.localToScene = identityMatrix();
        localPlayerGeometry.normalToScene = paddedLinearColumns(identityMatrix());
        localPlayerGeometry.metadataFlags = kRTInstanceFlagDynamicVertexBuffer;
        localPlayerGeometry.instanceMask = kLocalPlayerShadowInstanceMask;
        dynamicTLASBoundsValid = false;
        dynamicTLASBoundsMinimum.fill(0.0F);
        dynamicTLASBoundsMaximum.fill(0.0F);
        dynamicTLASVertexCount = 0;
        topLevel = nil;
        instanceDescriptorBuffer = nil;
        instanceMetadataBuffer = nil;
        activeSerials.clear();
        activeTransforms.clear();
        activeTextureIds.clear();
        activeMetadataFlags.clear();
        activeBottomLevels.clear();
        projection.fill(0.0F);
        sceneAnchorValid = false;
        sceneEpoch = 0;
        viewToScene = identityMatrix();
        worldToSceneLinear = paddedLinearColumns(identityMatrix());
        anchorWorldCamera.fill(0.0);
        anchorWorldCameraValid = false;
        ++generation;
    }

    bool ensureDynamicCanonicalCapacity(std::size_t requiredVertexCount,
                                        std::string &error) {
        DynamicFrameResources &frame = dynamicFrames[dynamicFrameIndex];
        if (frame.canonicalVertices != nil &&
            requiredVertexCount <= frame.canonicalVertexCapacity) {
            return true;
        }

        std::size_t capacity = std::max(
            frame.canonicalVertexCapacity, kInitialDynamicVertexCapacity);
        while (capacity < requiredVertexCount) {
            if (capacity > std::numeric_limits<std::size_t>::max() / 2U) {
                capacity = requiredVertexCount;
                break;
            }
            capacity *= 2U;
        }
        std::size_t byteLength = 0;
        if (!checkedMultiply(capacity, sizeof(RTVertex), byteLength) ||
            byteLength > std::numeric_limits<NSUInteger>::max()) {
            error = "dynamic canonical ring allocation exceeds Metal's size range";
            return false;
        }

        id<MTLBuffer> replacement = [device
            newBufferWithLength:static_cast<NSUInteger>(byteLength)
                        options:MTLResourceStorageModeShared];
        if (replacement == nil || replacement.contents == nullptr) {
            error = "Metal failed to grow a dynamic canonical ring slot";
            return false;
        }
        replacement.label = [NSString stringWithFormat:
            @"ShaderMetal RT Dynamic Canonical Vertices [%zu]",
            dynamicFrameIndex];
        frame.canonicalVertices = replacement;
        frame.canonicalVertexCapacity = capacity;
        return true;
    }

    bool ensureDynamicScratchCapacity(std::size_t requiredByteCount,
                                      std::string &error) {
        if (requiredByteCount == 0) {
            return true;
        }
        DynamicFrameResources &frame = dynamicFrames[dynamicFrameIndex];
        if (frame.scratchBuffer != nil &&
            requiredByteCount <= frame.scratchByteCapacity) {
            return true;
        }

        std::size_t capacity = std::max(
            frame.scratchByteCapacity, kInitialDynamicScratchCapacity);
        while (capacity < requiredByteCount) {
            if (capacity > std::numeric_limits<std::size_t>::max() / 2U) {
                capacity = requiredByteCount;
                break;
            }
            capacity *= 2U;
        }
        if (capacity > std::numeric_limits<NSUInteger>::max()) {
            error = "dynamic BLAS scratch ring exceeds Metal's size range";
            return false;
        }

        id<MTLBuffer> replacement = [device
            newBufferWithLength:static_cast<NSUInteger>(capacity)
                        options:MTLResourceStorageModePrivate];
        if (replacement == nil) {
            error = "Metal failed to grow a dynamic BLAS scratch ring slot";
            return false;
        }
        replacement.label = [NSString stringWithFormat:
            @"ShaderMetal Dynamic Entity BLAS Scratch [%zu]",
            dynamicFrameIndex];
        frame.scratchBuffer = replacement;
        frame.scratchByteCapacity = capacity;
        return true;
    }

    bool ensureCanonicalCapacity(std::size_t requiredVertexCount,
                                 std::string &error) {
        if (requiredVertexCount <= canonicalVertexCapacity) {
            return true;
        }
        if (requiredVertexCount > std::numeric_limits<std::uint32_t>::max()) {
            error = "canonical RT vertex count exceeds the 32-bit user_instance_id range";
            return false;
        }

        std::size_t capacity = std::max(canonicalVertexCapacity,
                                        kInitialCanonicalVertexCapacity);
        while (capacity < requiredVertexCount) {
            if (capacity > std::numeric_limits<std::uint32_t>::max() / 2) {
                capacity = requiredVertexCount;
                break;
            }
            capacity *= 2;
        }

        std::size_t byteLength = 0;
        if (!checkedMultiply(capacity, sizeof(RTVertex), byteLength) ||
            byteLength > std::numeric_limits<NSUInteger>::max()) {
            error = "canonical RT vertex allocation exceeds Metal's size range";
            return false;
        }

        id<MTLBuffer> replacement = [device
            newBufferWithLength:static_cast<NSUInteger>(byteLength)
                        options:MTLResourceStorageModeShared];
        if (replacement == nil || replacement.contents == nullptr) {
            error = "Metal failed to grow the shared canonical RT vertex buffer";
            return false;
        }
        replacement.label = @"ShaderMetal RT Canonical Vertices";

        std::size_t retainedBytes = 0;
        if (!checkedMultiply(canonicalVertexCount, sizeof(RTVertex), retainedBytes)) {
            error = "canonical RT retained byte count overflows size_t";
            return false;
        }
        if (retainedBytes != 0) {
            if (canonicalVertexBuffer == nil ||
                canonicalVertexBuffer.contents == nullptr) {
                error = "canonical RT buffer lost CPU visibility while growing";
                return false;
            }
            std::memcpy(replacement.contents, canonicalVertexBuffer.contents,
                        retainedBytes);
        }
        canonicalVertexBuffer = replacement;
        canonicalVertexCapacity = capacity;
        return true;
    }

    bool takeReusableCanonicalRange(std::size_t count, std::size_t &offset) {
        std::size_t bestIndex = canonicalFreeRanges.size();
        std::size_t bestCount = std::numeric_limits<std::size_t>::max();
        for (std::size_t index = 0; index < canonicalFreeRanges.size(); ++index) {
            const CanonicalFreeRange &range = canonicalFreeRanges[index];
            if (range.availableAfterFrame <= frameOrdinal &&
                range.count >= count && range.count < bestCount) {
                bestIndex = index;
                bestCount = range.count;
            }
        }
        if (bestIndex == canonicalFreeRanges.size()) {
            return false;
        }
        CanonicalFreeRange &range = canonicalFreeRanges[bestIndex];
        offset = range.offset;
        range.offset += count;
        range.count -= count;
        if (range.count == 0) {
            canonicalFreeRanges.erase(canonicalFreeRanges.begin() +
                                      static_cast<std::ptrdiff_t>(bestIndex));
        }
        return true;
    }

    void retireCanonicalRange(std::size_t offset, std::size_t count,
                              std::uint64_t availableAfterFrame) {
        if (count == 0) {
            return;
        }
        try {
            CanonicalFreeRange merged{offset, count, availableAfterFrame};
            for (std::size_t index = 0; index < canonicalFreeRanges.size();) {
                CanonicalFreeRange &existing = canonicalFreeRanges[index];
                std::size_t existingEnd = 0;
                std::size_t mergedEnd = 0;
                if (!checkedAdd(existing.offset, existing.count, existingEnd) ||
                    !checkedAdd(merged.offset, merged.count, mergedEnd) ||
                    (existingEnd != merged.offset && mergedEnd != existing.offset)) {
                    ++index;
                    continue;
                }
                merged.offset = std::min(merged.offset, existing.offset);
                if (!checkedAdd(merged.count, existing.count, merged.count)) {
                    ++index;
                    continue;
                }
                merged.availableAfterFrame = std::max(
                    merged.availableAfterFrame, existing.availableAfterFrame);
                canonicalFreeRanges.erase(canonicalFreeRanges.begin() +
                                          static_cast<std::ptrdiff_t>(index));
            }
            canonicalFreeRanges.push_back(merged);
        } catch (const std::bad_alloc &) {
            // Losing reuse metadata leaks capacity, never live GPU data.
        }
    }

    void retireCanonicalRange(const Geometry &geometry) {
        const std::uint64_t availableAfterFrame =
            frameOrdinal > std::numeric_limits<std::uint64_t>::max() -
                               kCanonicalReuseDelayFrames
            ? std::numeric_limits<std::uint64_t>::max()
            : frameOrdinal + kCanonicalReuseDelayFrames;
        retireCanonicalRange(geometry.canonicalVertexOffset,
                             geometry.canonicalVertexCount,
                             availableAfterFrame);
    }
};

AccelStructManager &AccelStructManager::shared() {
    static AccelStructManager manager;
    return manager;
}

AccelStructManager::AccelStructManager() : impl_(std::make_unique<Impl>()) {}

AccelStructManager::~AccelStructManager() = default;

bool AccelStructManager::beginFrame(id<MTLDevice> device, std::string &error) {
    error.clear();
    if (device == nil) {
        error = "cannot begin an RT scene frame without a Metal device";
        return false;
    }
    if (!device.supportsRaytracing) {
        error = "the active Metal device does not support hardware ray tracing";
        return false;
    }

    std::lock_guard lock(impl_->mutex);
    if (impl_->device != nil && impl_->device != device) {
        impl_->resetScene();
    }
    impl_->device = device;
    impl_->frameOpen = true;
    if (impl_->frameOrdinal != std::numeric_limits<std::uint64_t>::max()) {
        ++impl_->frameOrdinal;
    }
    impl_->dynamicFrameIndex =
        (impl_->dynamicFrameIndex + 1U) % kDynamicFramesInFlight;
    impl_->dynamicFrames[impl_->dynamicFrameIndex].stagingVertices.clear();
    impl_->observedInstances.clear();
    impl_->excludedThisFrame.clear();
    impl_->dynamicObservations.clear();
    impl_->observedDynamicDrawCount = 0;
    impl_->rejectedDynamicDrawCount = 0;
    impl_->dynamicObservationDiagnostic.clear();
    impl_->localPlayerShadowProxy = {};
    impl_->observedProjectionValid = false;
    return true;
}

bool AccelStructManager::observeWorldDraw(const WorldDrawInput &draw,
                                          std::string &error) {
    error.clear();
    if (draw.vertexBufferId <= 0 || draw.indexBufferId <= 0) {
        error = "ray-tracing terrain draw references an invalid buffer ID";
        return false;
    }
    if (draw.vertexFormatType != kTerrainVertexFormat ||
        draw.vertexStride != kTerrainVertexStride) {
        error = "ray tracing accepts only terrain vertex format 0 with 32-byte stride";
        return false;
    }
    if (draw.drawMode != kTriangleDrawMode && draw.drawMode != kQuadDrawMode) {
        error = "ray tracing accepts only triangle or converted-quad terrain draws";
        return false;
    }
    if (draw.drawMode == kQuadDrawMode && draw.indexCount % 6 != 0) {
        error = "converted-quad terrain draw does not contain two triangles per quad";
        return false;
    }
    if (draw.indexCount <= 0 || draw.indexCount % 3 != 0 ||
        draw.firstIndex < 0) {
        error = "ray-tracing terrain indices must be a nonempty triangle list";
        return false;
    }
    std::size_t ignoredIndexSize = 0;
    if (!indexElementSize(draw.indexType, ignoredIndexSize)) {
        error = "ray-tracing terrain index type must be uint16 or uint32";
        return false;
    }
    if (draw.textureId < 0) {
        error = "ray-tracing terrain draw has an invalid texture ID";
        return false;
    }
    const std::uint32_t allowedMaterialFlags =
        kRTInstanceFlagOpaque | kRTInstanceFlagTranslucent |
        kRTInstanceFlagAlphaTest;
    const bool opaqueSurface =
        (draw.metadataFlags & kRTInstanceFlagOpaque) != 0U;
    const bool translucentSurface =
        (draw.metadataFlags & kRTInstanceFlagTranslucent) != 0U;
    if ((draw.metadataFlags & ~allowedMaterialFlags) != 0U ||
        opaqueSurface == translucentSurface ||
        ((draw.metadataFlags & kRTInstanceFlagAlphaTest) != 0U &&
         !opaqueSurface)) {
        error = "ray-tracing terrain draw has invalid material flags";
        return false;
    }
    if (!finiteMatrix(draw.modelView) || !finiteMatrix(draw.projection) ||
        !affineModelView(draw.modelView)) {
        error = "ray-tracing terrain draw has a non-finite or non-affine transform";
        return false;
    }

    std::array<float, 12> normalToView{};
    if (!normalMatrixForModelView(draw.modelView, normalToView)) {
        error = "ray-tracing terrain draw has a singular model-view transform";
        return false;
    }

    std::lock_guard lock(impl_->mutex);
    if (!impl_->frameOpen || impl_->device == nil) {
        error = "ray-tracing terrain draw was observed outside beginFrame/encodeUpdates";
        return false;
    }
    if (impl_->observedProjectionValid &&
        impl_->observedProjection != draw.projection) {
        error = "persistent terrain draws disagree on the current projection matrix";
        return false;
    }

    const GeometryKey key{
        draw.vertexBufferId,
        draw.indexBufferId,
        draw.vertexFormatType,
        draw.vertexStride,
        draw.drawMode,
        draw.indexCount,
        draw.indexType,
        draw.firstIndex,
        draw.firstVertex,
        draw.textureId,
    };

    Geometry *geometry = nullptr;
    const auto found = impl_->geometries.find(key);
    if (found != impl_->geometries.end()) {
        geometry = found->second.get();
        if (!sameGeometryLayout(geometry->key, key)) {
            error = "persistent buffer IDs were reused with a different terrain draw range";
            impl_->excludedThisFrame.insert(geometry->serial);
            impl_->observedInstances.erase(geometry->serial);
            return false;
        }
        if (geometry->key.indexBufferId != draw.indexBufferId) {
            id<MTLBuffer> indexBuffer =
                BufferManager::shared().buffer(draw.indexBufferId);
            const std::size_t indexBufferSize =
                BufferManager::shared().size(draw.indexBufferId);
            const std::uint32_t indexUsage =
                BufferManager::shared().usageFlags(draw.indexBufferId);
            if (indexBuffer == nil || indexBuffer.device != impl_->device ||
                indexBuffer.storageMode != MTLStorageModeShared ||
                indexBuffer.contents == nullptr || indexBufferSize == 0 ||
                indexBufferSize > indexBuffer.length ||
                (indexUsage & kPersistentIndexUsage) == 0 ||
                !validateSourceRanges(draw, geometry->sourceVertexBytes,
                                      indexBufferSize, error)) {
                if (error.empty()) {
                    error = "re-sorted terrain index buffer is invalid";
                }
                return false;
            }
            // Translucent sorting only changes triangle order. Keep the existing
            // canonical triangles and BLAS, but retain the newest source in case
            // a later material-mode change legitimately requires a rebuild.
            geometry->key.indexBufferId = draw.indexBufferId;
            geometry->sourceIndices = indexBuffer;
            geometry->sourceIndexBytes = indexBufferSize;
        }
        const bool traversalModeChanged =
            usesProgrammableIntersection(geometry->metadataFlags) !=
            usesProgrammableIntersection(draw.metadataFlags);
        geometry->textureId = draw.textureId;
        geometry->metadataFlags = draw.metadataFlags;
        if (traversalModeChanged && geometry->state != GeometryState::PendingExpansion &&
            geometry->state != GeometryState::Rejected) {
            geometry->state = GeometryState::PendingBuild;
            geometry->bottomLevel = nil;
        }
    } else {
        if (impl_->nextGeometrySerial ==
            std::numeric_limits<std::uint64_t>::max()) {
            error = "persistent terrain geometry serial space is exhausted";
            return false;
        }
        id<MTLBuffer> vertexBuffer =
            BufferManager::shared().buffer(draw.vertexBufferId);
        id<MTLBuffer> indexBuffer =
            BufferManager::shared().buffer(draw.indexBufferId);
        const std::size_t vertexBufferSize =
            BufferManager::shared().size(draw.vertexBufferId);
        const std::size_t indexBufferSize =
            BufferManager::shared().size(draw.indexBufferId);
        const std::uint32_t vertexUsage =
            BufferManager::shared().usageFlags(draw.vertexBufferId);
        const std::uint32_t indexUsage =
            BufferManager::shared().usageFlags(draw.indexBufferId);
        if (vertexBuffer == nil || indexBuffer == nil ||
            vertexBuffer.device != impl_->device ||
            indexBuffer.device != impl_->device) {
            error = "ray-tracing terrain buffers are missing or belong to another device";
            return false;
        }
        if ((vertexUsage & kPersistentVertexUsage) == 0 ||
            (indexUsage & kPersistentIndexUsage) == 0) {
            error = "ray tracing ignores non-persistent world buffers";
            return false;
        }
        if (vertexBuffer.storageMode != MTLStorageModeShared ||
            indexBuffer.storageMode != MTLStorageModeShared ||
            vertexBuffer.contents == nullptr || indexBuffer.contents == nullptr) {
            error = "ray-tracing terrain expansion requires CPU-visible shared buffers";
            return false;
        }
        if (vertexBufferSize == 0 || indexBufferSize == 0 ||
            vertexBufferSize > vertexBuffer.length ||
            indexBufferSize > indexBuffer.length ||
            !validateSourceRanges(draw, vertexBufferSize, indexBufferSize, error)) {
            if (error.empty()) {
                error = "ray-tracing terrain buffer size metadata is invalid";
            }
            return false;
        }

        try {
            auto newGeometry = std::make_unique<Geometry>();
            newGeometry->key = key;
            newGeometry->serial = impl_->nextGeometrySerial++;
            newGeometry->sourceVertices = vertexBuffer;
            newGeometry->sourceIndices = indexBuffer;
            newGeometry->sourceVertexBytes = vertexBufferSize;
            newGeometry->sourceIndexBytes = indexBufferSize;
            newGeometry->textureId = draw.textureId;
            newGeometry->metadataFlags = draw.metadataFlags;
            geometry = newGeometry.get();
            impl_->geometries.emplace(key, std::move(newGeometry));
        } catch (const std::bad_alloc &) {
            error = "unable to retain a persistent terrain geometry";
            return false;
        }
    }

    if (geometry->state == GeometryState::Rejected) {
        error = geometry->rejectionReason.empty()
            ? "persistent terrain geometry was rejected during canonical expansion"
            : geometry->rejectionReason;
        return false;
    }

    const auto duplicate = impl_->observedInstances.find(geometry->serial);
    if (duplicate != impl_->observedInstances.end() &&
        duplicate->second.modelView != draw.modelView) {
        error = "one persistent geometry was observed with multiple transforms in a frame";
        impl_->observedInstances.erase(duplicate);
        impl_->excludedThisFrame.insert(geometry->serial);
        return false;
    }
    if (impl_->excludedThisFrame.contains(geometry->serial)) {
        error = "persistent geometry is excluded after conflicting draws in this frame";
        return false;
    }

    try {
        impl_->observedInstances[geometry->serial] =
            ObservedInstance{geometry, draw.modelView, normalToView};
    } catch (const std::bad_alloc &) {
        error = "unable to retain a ray-tracing terrain instance";
        return false;
    }
    impl_->observedProjection = draw.projection;
    impl_->observedProjectionValid = true;
    return true;
}

bool AccelStructManager::observeDynamicEntityDraw(
    const DynamicEntityDrawInput &draw, std::string &error) {
    error.clear();
    std::lock_guard lock(impl_->mutex);
    if (!impl_->frameOpen || impl_->device == nil) {
        error = "dynamic entity draw was observed outside beginFrame/encodeUpdates";
        return false;
    }

    ++impl_->observedDynamicDrawCount;
    const auto reject = [&](std::string message) {
        ++impl_->rejectedDynamicDrawCount;
        if (impl_->dynamicObservationDiagnostic.empty()) {
            impl_->dynamicObservationDiagnostic = message;
        }
        error = std::move(message);
        return false;
    };
    if (impl_->dynamicObservations.size() >= kMaximumObservedDynamicDraws) {
        return reject("dynamic entity observation count exceeds the per-frame limit");
    }
    if (draw.vertexBufferId <= 0 || draw.indexBufferId <= 0) {
        return reject("dynamic entity draw references an invalid buffer ID");
    }
    if (draw.vertexFormatType != kEntityVertexFormat ||
        draw.vertexStride != kEntityVertexStride) {
        return reject(
            "dynamic RT accepts only entity vertex format 1 with 36-byte stride");
    }
    if (draw.drawMode != kTriangleDrawMode && draw.drawMode != kQuadDrawMode) {
        return reject("dynamic RT accepts only triangle or converted-quad draws");
    }
    if (draw.drawMode == kQuadDrawMode && draw.indexCount % 6 != 0) {
        return reject(
            "converted-quad entity draw does not contain two triangles per quad");
    }
    if (draw.instanceCount != 1) {
        return reject("dynamic RT accepts only single-instance entity draws");
    }
    if (draw.indexCount <= 0 || draw.indexCount % 3 != 0 ||
        draw.firstIndex < 0) {
        return reject("dynamic entity indices must be a nonempty triangle list");
    }
    std::size_t ignoredIndexSize = 0;
    if (!indexElementSize(draw.indexType, ignoredIndexSize)) {
        return reject("dynamic entity index type must be uint16 or uint32");
    }
    if (draw.textureId < 0 ||
        static_cast<std::uint32_t>(draw.textureId) > kDynamicTextureIdMask) {
        return reject("dynamic entity texture ID exceeds the packed material range");
    }
    const std::uint32_t allowedMaterialFlags =
        kRTInstanceFlagOpaque | kRTInstanceFlagTranslucent |
        kRTInstanceFlagAlphaTest;
    const bool opaqueSurface =
        (draw.materialFlags & kRTInstanceFlagOpaque) != 0U;
    const bool translucentSurface =
        (draw.materialFlags & kRTInstanceFlagTranslucent) != 0U;
    if ((draw.materialFlags & ~allowedMaterialFlags) != 0U ||
        opaqueSurface == translucentSurface ||
        ((draw.materialFlags & kRTInstanceFlagAlphaTest) != 0U &&
         !opaqueSurface)) {
        return reject("dynamic entity draw has invalid material flags");
    }
    if (!finiteMatrix(draw.modelView) || !affineModelView(draw.modelView)) {
        return reject("dynamic entity draw has a non-finite or non-affine transform");
    }
    std::array<float, 12> ignoredNormalMatrix{};
    if (!normalMatrixForModelView(draw.modelView, ignoredNormalMatrix)) {
        return reject("dynamic entity draw has a singular model-view transform");
    }

    BufferManager &buffers = BufferManager::shared();
    id<MTLBuffer> vertexBuffer = buffers.buffer(draw.vertexBufferId);
    id<MTLBuffer> indexBuffer = buffers.buffer(draw.indexBufferId);
    const std::size_t vertexBufferSize = buffers.size(draw.vertexBufferId);
    const std::size_t indexBufferSize = buffers.size(draw.indexBufferId);
    if (vertexBuffer == nil || indexBuffer == nil ||
        vertexBuffer.device != impl_->device || indexBuffer.device != impl_->device) {
        return reject("dynamic entity buffers are missing or belong to another device");
    }
    if (vertexBuffer.storageMode != MTLStorageModeShared ||
        indexBuffer.storageMode != MTLStorageModeShared ||
        vertexBuffer.contents == nullptr || indexBuffer.contents == nullptr) {
        return reject("dynamic entity expansion requires CPU-visible shared buffers");
    }
    std::string rangeError;
    if (vertexBufferSize == 0 || indexBufferSize == 0 ||
        vertexBufferSize > vertexBuffer.length ||
        indexBufferSize > indexBuffer.length ||
        !validateDynamicSourceRanges(draw, vertexBufferSize, indexBufferSize,
                                     rangeError)) {
        return reject(rangeError.empty()
            ? "dynamic entity buffer size metadata is invalid"
            : std::move(rangeError));
    }

    try {
        impl_->dynamicObservations.push_back(DynamicObservation{
            draw, vertexBuffer, indexBuffer, vertexBufferSize, indexBufferSize});
    } catch (const std::bad_alloc &) {
        return reject("unable to retain a dynamic entity RT observation");
    }
    return true;
}

bool AccelStructManager::setLocalPlayerShadowProxy(
    const LocalPlayerShadowProxyInput &proxy, std::string &error) {
    error.clear();
    std::lock_guard lock(impl_->mutex);
    if (!impl_->frameOpen || impl_->device == nil) {
        error = "local-player shadow proxy was set outside beginFrame/encodeUpdates";
        return false;
    }
    const bool finiteInput = std::all_of(
        proxy.cameraRelativePosition.begin(),
        proxy.cameraRelativePosition.end(),
        [](float value) { return std::isfinite(value); }) &&
        std::isfinite(proxy.bodyYawRadians) &&
        std::isfinite(proxy.limbPhase) &&
        std::isfinite(proxy.limbAmplitude) &&
        std::isfinite(proxy.handSwingProgress) &&
        std::isfinite(proxy.headYawRadians) &&
        std::isfinite(proxy.headPitchRadians);
    if (!finiteInput || proxy.pose > 2U) {
        error = "local-player shadow proxy contains invalid pose or animation data";
        return false;
    }
    impl_->localPlayerShadowProxy = proxy;
    return true;
}

AccelerationUpdateResult AccelStructManager::encodeUpdates(
    id<MTLCommandBuffer> commandBuffer,
    const AccelerationBuildBudget &budget,
    const std::array<double, 3> &worldCameraPosition,
    std::string &error) {
    AccelerationUpdateResult result;
    std::string firstDiagnostic;
    error.clear();
    if (commandBuffer == nil) {
        error = "cannot encode RT acceleration updates without a command buffer";
        return result;
    }
    if (!std::all_of(worldCameraPosition.begin(), worldCameraPosition.end(),
                     [](double value) { return std::isfinite(value); })) {
        error = "cannot anchor the RT scene to a non-finite camera position";
        return result;
    }

    std::lock_guard lock(impl_->mutex);
    if (!impl_->frameOpen || impl_->device == nil) {
        error = "RT acceleration updates were encoded outside an active frame";
        return result;
    }
    impl_->frameOpen = false;
    result.observedInstanceCount = impl_->observedInstances.size();
    result.observedDynamicDrawCount = impl_->observedDynamicDrawCount;
    result.skippedDynamicDrawCount = impl_->rejectedDynamicDrawCount;
    result.dynamicFirstDiagnostic = impl_->dynamicObservationDiagnostic;

    struct TransformCluster final {
        std::size_t instanceCount = 0;
        std::size_t quadCount = 0;
    };
    std::unordered_map<LinearTransformKey, TransformCluster,
                       LinearTransformKeyHash> transformClusters;
    std::optional<LinearTransformKey> dominantTransform;
    std::size_t dominantCount = 0;
    std::size_t dominantQuadCount = 0;
    std::unordered_set<std::uint64_t> eligibleSerials;
    try {
        transformClusters.reserve(impl_->observedInstances.size());
        eligibleSerials.reserve(impl_->observedInstances.size());
        for (const auto &[serial, observed] : impl_->observedInstances) {
            (void)serial;
            LinearTransformKey transformKey;
            if (!linearTransformKey(observed.modelView, transformKey)) {
                continue;
            }
            TransformCluster &cluster = transformClusters[transformKey];
            ++cluster.instanceCount;
            if (observed.geometry->key.drawMode == kQuadDrawMode) {
                ++cluster.quadCount;
            }
        }
        for (const auto &[transform, cluster] : transformClusters) {
            if (cluster.instanceCount > dominantCount ||
                (cluster.instanceCount == dominantCount &&
                 cluster.quadCount > dominantQuadCount)) {
                dominantTransform = transform;
                dominantCount = cluster.instanceCount;
                dominantQuadCount = cluster.quadCount;
            }
        }

        // Terrain chunks share the camera's linear view transform; persistent
        // entity/tool meshes generally form tiny rotated/scaled outlier groups.
        // Do not promote an incoherent large draw set into the RT scene.
        if (impl_->observedInstances.size() >= 8 && dominantCount < 4) {
            dominantTransform.reset();
        }
        if (dominantTransform.has_value()) {
            for (const auto &[serial, observed] : impl_->observedInstances) {
                LinearTransformKey transformKey;
                if (linearTransformKey(observed.modelView, transformKey) &&
                    transformKey == *dominantTransform) {
                    eligibleSerials.insert(serial);
                    observed.geometry->terrainConfirmed = true;
                }
            }
        }
    } catch (const std::bad_alloc &) {
        error = "unable to classify persistent terrain transforms";
        return result;
    }
    result.filteredInstanceCount = impl_->observedInstances.size() -
                                   eligibleSerials.size();
    result.eligibleInstanceCount = eligibleSerials.size();
    if (eligibleSerials.empty() && !impl_->observedInstances.empty()) {
        firstDiagnostic =
            "persistent world draws did not contain a coherent terrain transform set";
    }

    std::vector<Geometry *> pending;
    try {
        pending.reserve(impl_->observedInstances.size());
        for (const auto &[serial, observed] : impl_->observedInstances) {
            if (!eligibleSerials.contains(serial)) {
                continue;
            }
            if (observed.geometry->state == GeometryState::PendingExpansion ||
                observed.geometry->state == GeometryState::PendingBuild) {
                pending.push_back(observed.geometry);
            } else if (observed.geometry->state == GeometryState::Rejected) {
                ++result.rejectedGeometryCount;
            }
        }
        std::sort(pending.begin(), pending.end(), [](const Geometry *left,
                                                     const Geometry *right) {
            return left->serial < right->serial;
        });
    } catch (const std::bad_alloc &) {
        error = "unable to schedule pending terrain BLAS builds";
        return result;
    }

    std::vector<Geometry *> selected;
    std::size_t selectedTriangles = 0;
    try {
        selected.reserve(std::min(pending.size(), budget.maxNewBottomLevelBuilds));
        for (Geometry *geometry : pending) {
            if (selected.size() >= budget.maxNewBottomLevelBuilds ||
                budget.maxNewTriangles == 0) {
                break;
            }
            const std::size_t triangleCount =
                static_cast<std::size_t>(geometry->key.indexCount) / 3;
            std::size_t nextTriangleCount = 0;
            if (!checkedAdd(selectedTriangles, triangleCount, nextTriangleCount)) {
                error = "terrain BLAS build budget overflows size_t";
                return result;
            }
            // Always make progress on one large chunk; subsequent chunks obey
            // the aggregate triangle budget strictly.
            if (!selected.empty() && nextTriangleCount > budget.maxNewTriangles) {
                continue;
            }
            selected.push_back(geometry);
            selectedTriangles = nextTriangleCount;
        }
    } catch (const std::bad_alloc &) {
        error = "unable to allocate the terrain BLAS build batch";
        return result;
    }

    std::vector<ExpandedGeometry> expansions;
    try {
        expansions.reserve(selected.size());
        for (Geometry *geometry : selected) {
            if (geometry->state != GeometryState::PendingExpansion) {
                continue;
            }
            ExpandedGeometry expansion;
            expansion.geometry = geometry;
            std::string expansionError;
            if (!expandGeometry(*geometry, expansion.vertices, expansionError)) {
                geometry->state = GeometryState::Rejected;
                geometry->rejectionReason = expansionError;
                ++result.rejectedGeometryCount;
                if (firstDiagnostic.empty()) {
                    firstDiagnostic = expansionError;
                }
                continue;
            }
            expansions.push_back(std::move(expansion));
        }
    } catch (const std::bad_alloc &) {
        error = "unable to retain expanded terrain geometry";
        return result;
    }

    const auto restoreReusableRanges = [&]() {
        for (const ExpandedGeometry &expansion : expansions) {
            if (expansion.reusedCanonicalRange) {
                impl_->retireCanonicalRange(
                    expansion.canonicalOffset, expansion.vertices.size(),
                    impl_->frameOrdinal);
            }
        }
    };
    std::size_t requiredCanonicalCount = impl_->canonicalVertexCount;
    for (ExpandedGeometry &expansion : expansions) {
        if (impl_->takeReusableCanonicalRange(
                expansion.vertices.size(), expansion.canonicalOffset)) {
            expansion.reusedCanonicalRange = true;
            continue;
        }
        expansion.canonicalOffset = requiredCanonicalCount;
        if (!checkedAdd(requiredCanonicalCount, expansion.vertices.size(),
                        requiredCanonicalCount)) {
            restoreReusableRanges();
            error = "canonical RT build batch overflows size_t";
            return result;
        }
    }
    if (!impl_->ensureCanonicalCapacity(requiredCanonicalCount, error)) {
        restoreReusableRanges();
        return result;
    }
    for (const ExpandedGeometry &expansion : expansions) {
        std::size_t destinationByteOffset = 0;
        std::size_t copyByteCount = 0;
        if (!checkedMultiply(expansion.canonicalOffset, sizeof(RTVertex),
                             destinationByteOffset) ||
            !checkedMultiply(expansion.vertices.size(), sizeof(RTVertex),
                             copyByteCount) ||
            destinationByteOffset > impl_->canonicalVertexBuffer.length ||
            copyByteCount > impl_->canonicalVertexBuffer.length -
                                destinationByteOffset) {
            restoreReusableRanges();
            error = "canonical RT allocation range overflows its Metal buffer";
            return result;
        }
    }
    for (ExpandedGeometry &expansion : expansions) {
        Geometry &geometry = *expansion.geometry;
        geometry.canonicalVertexOffset = expansion.canonicalOffset;
        geometry.canonicalVertexCount = expansion.vertices.size();
        const std::size_t destinationByteOffset =
            expansion.canonicalOffset * sizeof(RTVertex);
        const std::size_t copyByteCount =
            expansion.vertices.size() * sizeof(RTVertex);
        std::memcpy(static_cast<std::byte *>(impl_->canonicalVertexBuffer.contents) +
                        destinationByteOffset,
                    expansion.vertices.data(), copyByteCount);
        geometry.state = GeometryState::PendingBuild;
        geometry.sourceVertices = nil;
        geometry.sourceIndices = nil;
    }
    impl_->canonicalVertexCount = requiredCanonicalCount;

    std::vector<BottomLevelBuild> bottomLevelBuilds;
    try {
        bottomLevelBuilds.reserve(selected.size());
        for (Geometry *geometry : selected) {
            if (geometry->state != GeometryState::PendingBuild) {
                continue;
            }
            if (geometry->canonicalVertexCount == 0 ||
                geometry->canonicalVertexCount % 3 != 0) {
                geometry->state = GeometryState::Rejected;
                geometry->rejectionReason =
                    "canonical terrain geometry is not a triangle list";
                ++result.rejectedGeometryCount;
                if (firstDiagnostic.empty()) {
                    firstDiagnostic = geometry->rejectionReason;
                }
                continue;
            }

            std::size_t vertexOffsetBytes = 0;
            if (!checkedMultiply(geometry->canonicalVertexOffset, sizeof(RTVertex),
                                 vertexOffsetBytes) ||
                vertexOffsetBytes > std::numeric_limits<NSUInteger>::max()) {
                geometry->state = GeometryState::Rejected;
                geometry->rejectionReason =
                    "canonical terrain vertex offset exceeds Metal's size range";
                ++result.rejectedGeometryCount;
                if (firstDiagnostic.empty()) {
                    firstDiagnostic = geometry->rejectionReason;
                }
                continue;
            }

            MTLAccelerationStructureTriangleGeometryDescriptor *triangle =
                [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
            triangle.vertexBuffer = impl_->canonicalVertexBuffer;
            triangle.vertexBufferOffset = static_cast<NSUInteger>(vertexOffsetBytes);
            triangle.vertexStride = sizeof(RTVertex);
            triangle.vertexFormat = MTLAttributeFormatFloat3;
            triangle.indexBuffer = nil;
            triangle.triangleCount = static_cast<NSUInteger>(
                geometry->canonicalVertexCount / 3);
            triangle.opaque =
                (geometry->metadataFlags &
                 (kRTInstanceFlagTranslucent | kRTInstanceFlagAlphaTest)) == 0U;
            triangle.allowDuplicateIntersectionFunctionInvocation = NO;

            MTLPrimitiveAccelerationStructureDescriptor *descriptor =
                [MTLPrimitiveAccelerationStructureDescriptor descriptor];
            descriptor.geometryDescriptors = @[triangle];
            descriptor.usage = accelerationStructureUsage(false);
            const MTLAccelerationStructureSizes sizes =
                [impl_->device accelerationStructureSizesWithDescriptor:descriptor];
            if (sizes.accelerationStructureSize == 0) {
                geometry->state = GeometryState::Rejected;
                geometry->rejectionReason =
                    "Metal reported a zero-sized terrain BLAS";
                ++result.rejectedGeometryCount;
                if (firstDiagnostic.empty()) {
                    firstDiagnostic = geometry->rejectionReason;
                }
                continue;
            }

            id<MTLAccelerationStructure> accelerationStructure =
                [impl_->device newAccelerationStructureWithSize:
                    sizes.accelerationStructureSize];
            const NSUInteger scratchLength =
                std::max<NSUInteger>(sizes.buildScratchBufferSize, 1);
            id<MTLBuffer> scratch = [impl_->device
                newBufferWithLength:scratchLength
                            options:MTLResourceStorageModePrivate];
            if (accelerationStructure == nil || scratch == nil) {
                if (firstDiagnostic.empty()) {
                    firstDiagnostic =
                        "Metal failed to allocate a terrain BLAS or scratch buffer";
                }
                continue;
            }
            accelerationStructure.label = [NSString stringWithFormat:
                @"ShaderMetal Terrain BLAS %llu",
                static_cast<unsigned long long>(geometry->serial)];
            scratch.label = @"ShaderMetal Terrain BLAS Scratch";
            geometry->bottomLevel = accelerationStructure;
            geometry->state = GeometryState::Scheduled;
            bottomLevelBuilds.push_back(BottomLevelBuild{
                geometry, descriptor, accelerationStructure, scratch});
        }
    } catch (const std::bad_alloc &) {
        error = "unable to retain terrain BLAS build commands";
        for (BottomLevelBuild &build : bottomLevelBuilds) {
            build.geometry->state = GeometryState::PendingBuild;
            build.geometry->bottomLevel = nil;
        }
        return result;
    }

    const auto startSceneEpoch = [&]() {
        if (impl_->sceneEpoch == std::numeric_limits<std::uint64_t>::max()) {
            for (auto &[key, geometry] : impl_->geometries) {
                (void)key;
                geometry->transformEpoch = 0;
            }
            impl_->sceneEpoch = 1;
        } else {
            ++impl_->sceneEpoch;
        }
        impl_->sceneAnchorValid = true;
        impl_->viewToScene = identityMatrix();
        impl_->anchorWorldCamera = worldCameraPosition;
        impl_->anchorWorldCameraValid = true;
        for (const auto &[serial, observed] : impl_->observedInstances) {
            if (eligibleSerials.contains(serial)) {
                impl_->worldToSceneLinear = paddedLinearColumns(
                    observed.modelView);
                break;
            }
        }
        result.reanchoredScene = true;
        ++impl_->generation;
    };

    if (!eligibleSerials.empty()) {
        if (!impl_->sceneAnchorValid) {
            startSceneEpoch();
        } else {
            const ObservedInstance *cameraReference = nullptr;
            std::uint64_t cameraReferenceSerial =
                std::numeric_limits<std::uint64_t>::max();
            for (const auto &[serial, observed] : impl_->observedInstances) {
                if (eligibleSerials.contains(serial) &&
                    serial < cameraReferenceSerial) {
                    cameraReference = &observed;
                    cameraReferenceSerial = serial;
                }
            }

            std::array<float, 16> derivedViewToScene{};
            const bool cameraDerived = cameraReference != nullptr &&
                impl_->anchorWorldCameraValid && deriveCameraAnchoredView(
                    impl_->worldToSceneLinear, cameraReference->modelView,
                    impl_->anchorWorldCamera, worldCameraPosition,
                    derivedViewToScene);
            const std::size_t anchorMatches = cameraDerived ? 0U : deriveViewToScene(
                impl_->observedInstances, eligibleSerials, impl_->sceneEpoch,
                derivedViewToScene);
            const std::size_t activeTerrainCount = static_cast<std::size_t>(
                std::count_if(impl_->activeSerials.begin(),
                              impl_->activeSerials.end(),
                              [](std::uint64_t serial) {
                    return serial != kDynamicGeometrySerial &&
                           serial != kLocalPlayerGeometrySerial;
                }));
            const std::size_t requiredAnchorMatches =
                activeTerrainCount > 1 ? 2 : 1;
            if (cameraDerived || anchorMatches >= requiredAnchorMatches) {
                if (impl_->viewToScene != derivedViewToScene) {
                    impl_->viewToScene = derivedViewToScene;
                    ++impl_->generation;
                }
            } else {
                // A world switch explicitly resets this manager. Reaching this
                // path therefore means a true long-distance camera cut or an
                // invalid transform, not ordinary high-speed chunk streaming.
                startSceneEpoch();
            }
        }
    }

    for (const auto &[serial, observed] : impl_->observedInstances) {
        if (!eligibleSerials.contains(serial) || !impl_->sceneAnchorValid) {
            continue;
        }
        Geometry &geometry = *observed.geometry;
        const std::array<float, 16> observedLocalToScene = multiplyMatrices(
            impl_->viewToScene, observed.modelView);
        if (!finiteMatrix(observedLocalToScene) ||
            !affineModelView(observedLocalToScene)) {
            continue;
        }
        if (geometry.transformEpoch != impl_->sceneEpoch ||
            !matricesNear(geometry.localToScene, observedLocalToScene)) {
            std::array<float, 12> normalToScene{};
            if (!normalMatrixForModelView(observedLocalToScene, normalToScene)) {
                continue;
            }
            geometry.transformEpoch = impl_->sceneEpoch;
            geometry.localToScene = observedLocalToScene;
            geometry.normalToScene = normalToScene;
        }
        geometry.lastVisibleFrame = impl_->frameOrdinal;
    }

    std::optional<DynamicBottomLevelBuild> dynamicBottomLevelBuild;
    std::optional<DynamicBottomLevelBuild> localPlayerBottomLevelBuild;
    bool dynamicTLASUpdateRequired = false;
    bool localPlayerTLASUpdateRequired = false;
    bool currentDynamicBoundsValid = false;
    std::array<float, 3> currentDynamicBoundsMinimum{};
    std::array<float, 3> currentDynamicBoundsMaximum{};
    std::vector<RTVertex> &dynamicVertices =
        impl_->dynamicFrames[impl_->dynamicFrameIndex].stagingVertices;
    std::size_t localPlayerVertexOffset = 0;
    std::size_t localPlayerVertexCount = 0;
    std::size_t dynamicEntityVertexOffset = 0;
    std::size_t dynamicEntityVertexCount = 0;
    std::size_t expandedDynamicDrawCount = 0;
    const auto recordDynamicDiagnostic = [&](const std::string &diagnostic) {
        if (result.dynamicFirstDiagnostic.empty()) {
            result.dynamicFirstDiagnostic = diagnostic;
        }
    };
    const std::size_t maximumDynamicTriangles = std::min(
        budget.maxDynamicTriangles, budget.maxDynamicVertices / 3U);

    if (impl_->localPlayerShadowProxy.enabled) {
        if (!impl_->sceneAnchorValid) {
            ++result.skippedDynamicDrawCount;
            recordDynamicDiagnostic(
                "local-player shadow proxy requires an anchored terrain scene");
        } else if (maximumDynamicTriangles <
                       kLocalPlayerProxyVertexCount / 3U) {
            ++result.skippedDynamicDrawCount;
            recordDynamicDiagnostic(
                "local-player shadow proxy exceeds the dynamic triangle budget");
        } else {
            localPlayerVertexOffset = dynamicVertices.size();
            if (appendLocalPlayerShadowProxy(
                    impl_->localPlayerShadowProxy, impl_->viewToScene,
                    impl_->worldToSceneLinear, dynamicVertices)) {
                localPlayerVertexCount =
                    dynamicVertices.size() - localPlayerVertexOffset;
            } else {
                ++result.skippedDynamicDrawCount;
                recordDynamicDiagnostic(
                    "unable to generate local-player shadow proxy vertices");
            }
        }
    }

    dynamicEntityVertexOffset = dynamicVertices.size();
    if (impl_->dynamicObservations.empty()) {
        // Removing last frame's dynamic instance is handled by TLAS topology
        // comparison below.
    } else if (!impl_->sceneAnchorValid) {
        result.skippedDynamicDrawCount += impl_->dynamicObservations.size();
        recordDynamicDiagnostic(
            "dynamic entities were skipped because the anchored terrain scene is unavailable");
    } else if (maximumDynamicTriangles == 0) {
        result.skippedDynamicDrawCount += impl_->dynamicObservations.size();
        recordDynamicDiagnostic("the dynamic entity triangle budget is zero");
    } else {
        std::size_t announcedVertexCount = dynamicVertices.size();
        for (const DynamicObservation &observation : impl_->dynamicObservations) {
            const std::size_t drawVertexCount =
                static_cast<std::size_t>(observation.draw.indexCount);
            if (drawVertexCount > budget.maxDynamicVertices -
                                      announcedVertexCount) {
                announcedVertexCount = budget.maxDynamicVertices;
                break;
            }
            announcedVertexCount += drawVertexCount;
        }
        bool reserveSucceeded = true;
        try {
            dynamicVertices.reserve(std::min(
                announcedVertexCount, maximumDynamicTriangles * 3U));
        } catch (const std::bad_alloc &) {
            result.skippedDynamicDrawCount += impl_->dynamicObservations.size();
            recordDynamicDiagnostic(
                "unable to reserve the frame-local dynamic canonical buffer");
            reserveSucceeded = false;
        }

        if (reserveSucceeded) {
            for (const DynamicObservation &observation :
                 impl_->dynamicObservations) {
                const std::size_t triangleCount =
                    static_cast<std::size_t>(observation.draw.indexCount) / 3U;
                const std::size_t currentTriangleCount = dynamicVertices.size() / 3U;
                if (triangleCount > maximumDynamicTriangles -
                                        currentTriangleCount ||
                    static_cast<std::size_t>(observation.draw.indexCount) >
                        budget.maxDynamicVertices - dynamicVertices.size()) {
                    ++result.skippedDynamicDrawCount;
                    recordDynamicDiagnostic(
                        "dynamic entity geometry exceeded the strict per-frame RT budget");
                    continue;
                }

                const std::array<float, 16> localToScene = multiplyMatrices(
                    impl_->viewToScene, observation.draw.modelView);
                if (!finiteMatrix(localToScene) ||
                    !affineModelView(localToScene)) {
                    ++result.skippedDynamicDrawCount;
                    recordDynamicDiagnostic(
                        "dynamic entity produced an invalid local-to-scene transform");
                    continue;
                }

                std::string expansionError;
                if (!expandDynamicEntity(observation, localToScene,
                                         dynamicVertices, expansionError)) {
                    ++result.skippedDynamicDrawCount;
                    recordDynamicDiagnostic(expansionError);
                    continue;
                }
                ++expandedDynamicDrawCount;
            }
        }
    }
    impl_->dynamicObservations.clear();
    dynamicEntityVertexCount = dynamicVertices.size() - dynamicEntityVertexOffset;

    if (!dynamicVertices.empty()) {
        std::size_t byteLength = 0;
        std::string sharedBufferError;
        if (!checkedMultiply(dynamicVertices.size(), sizeof(RTVertex), byteLength) ||
            byteLength > std::numeric_limits<NSUInteger>::max()) {
            sharedBufferError =
                "dynamic canonical entity data exceeds Metal's size range";
        } else if (!impl_->ensureDynamicCanonicalCapacity(
                       dynamicVertices.size(), sharedBufferError)) {
            // The helper provides the allocation diagnostic.
        }

        if (sharedBufferError.empty()) {
            DynamicFrameResources &frame =
                impl_->dynamicFrames[impl_->dynamicFrameIndex];
            id<MTLBuffer> dynamicBuffer = frame.canonicalVertices;
            std::memcpy(dynamicBuffer.contents, dynamicVertices.data(), byteLength);
            impl_->dynamicCanonicalVertexBuffer = dynamicBuffer;
            impl_->dynamicCanonicalVertexCount = dynamicVertices.size();

            const auto prepareBottomLevel = [&](
                Geometry &geometry, std::size_t vertexOffset,
                std::size_t vertexCount, NSString *label,
                std::string &resourceError)
                -> std::optional<DynamicBottomLevelBuild> {
                std::size_t vertexOffsetBytes = 0;
                if (vertexCount == 0 || vertexCount % 3U != 0 ||
                    !checkedMultiply(vertexOffset, sizeof(RTVertex),
                                     vertexOffsetBytes) ||
                    vertexOffsetBytes > std::numeric_limits<NSUInteger>::max()) {
                    resourceError =
                        "dynamic BLAS vertex range exceeds Metal's size range";
                    return std::nullopt;
                }

                MTLAccelerationStructureTriangleGeometryDescriptor *triangle =
                    [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
                triangle.vertexBuffer = dynamicBuffer;
                triangle.vertexBufferOffset =
                    static_cast<NSUInteger>(vertexOffsetBytes);
                triangle.vertexStride = sizeof(RTVertex);
                triangle.vertexFormat = MTLAttributeFormatFloat3;
                triangle.indexBuffer = nil;
                triangle.triangleCount = static_cast<NSUInteger>(vertexCount / 3U);
                triangle.opaque = NO;
                triangle.allowDuplicateIntersectionFunctionInvocation = NO;

                MTLPrimitiveAccelerationStructureDescriptor *descriptor =
                    [MTLPrimitiveAccelerationStructureDescriptor descriptor];
                descriptor.geometryDescriptors = @[triangle];
                descriptor.usage = MTLAccelerationStructureUsagePreferFastBuild |
                                   MTLAccelerationStructureUsageRefit;
                const MTLAccelerationStructureSizes sizes =
                    [impl_->device accelerationStructureSizesWithDescriptor:descriptor];
                id<MTLAccelerationStructure> previous = geometry.bottomLevel;
                id<MTLAccelerationStructure> accelerationStructure = previous;
                const bool needsAllocation = accelerationStructure == nil ||
                    accelerationStructure.size < sizes.accelerationStructureSize;
                if (needsAllocation && sizes.accelerationStructureSize != 0) {
                    accelerationStructure = [impl_->device
                        newAccelerationStructureWithSize:
                            sizes.accelerationStructureSize];
                }
                const bool canRefit = !needsAllocation &&
                    accelerationStructure != nil &&
                    geometry.state == GeometryState::Ready &&
                    geometry.canonicalVertexOffset == vertexOffset &&
                    geometry.canonicalVertexCount == vertexCount;
                const std::size_t scratchLength = canRefit
                    ? static_cast<std::size_t>(sizes.refitScratchBufferSize)
                    : static_cast<std::size_t>(
                        std::max<NSUInteger>(sizes.buildScratchBufferSize, 1));
                if (sizes.accelerationStructureSize == 0 ||
                    accelerationStructure == nil) {
                    resourceError = "Metal failed to allocate a dynamic BLAS";
                    return std::nullopt;
                }
                if (!impl_->ensureDynamicScratchCapacity(
                        scratchLength, resourceError)) {
                    return std::nullopt;
                }
                id<MTLBuffer> scratch = scratchLength == 0
                    ? nil : frame.scratchBuffer;
                accelerationStructure.label = label;
                geometry.canonicalVertexOffset = vertexOffset;
                geometry.canonicalVertexCount = vertexCount;
                geometry.textureId = -1;
                geometry.state = GeometryState::Scheduled;
                geometry.bottomLevel = accelerationStructure;
                geometry.localToScene = identityMatrix();
                geometry.normalToScene = paddedLinearColumns(identityMatrix());
                geometry.metadataFlags = kRTInstanceFlagDynamicVertexBuffer;
                return DynamicBottomLevelBuild{
                    canRefit, descriptor, accelerationStructure, scratch};
            };

            if (dynamicEntityVertexCount != 0) {
                std::string entityResourceError;
                currentDynamicBoundsValid = dynamicSceneBounds(
                    dynamicVertices, dynamicEntityVertexOffset,
                    dynamicEntityVertexCount, currentDynamicBoundsMinimum,
                    currentDynamicBoundsMaximum);
                if (!currentDynamicBoundsValid) {
                    entityResourceError =
                        "dynamic entity bounds contain invalid positions";
                } else {
                    id<MTLAccelerationStructure> previous =
                        impl_->dynamicGeometry.bottomLevel;
                    dynamicBottomLevelBuild = prepareBottomLevel(
                        impl_->dynamicGeometry, dynamicEntityVertexOffset,
                        dynamicEntityVertexCount,
                        @"ShaderMetal Dynamic Entity BLAS",
                        entityResourceError);
                    if (dynamicBottomLevelBuild.has_value()) {
                        const bool dynamicWasActive = std::find(
                            impl_->activeSerials.begin(),
                            impl_->activeSerials.end(),
                            kDynamicGeometrySerial) != impl_->activeSerials.end();
                        dynamicTLASUpdateRequired = !dynamicWasActive ||
                            previous != impl_->dynamicGeometry.bottomLevel ||
                            impl_->dynamicTLASVertexCount !=
                                dynamicEntityVertexCount ||
                            !impl_->dynamicTLASBoundsValid ||
                            !boundsContained(currentDynamicBoundsMinimum,
                                             currentDynamicBoundsMaximum,
                                             impl_->dynamicTLASBoundsMinimum,
                                             impl_->dynamicTLASBoundsMaximum);
                    }
                }
                if (!entityResourceError.empty()) {
                    result.skippedDynamicDrawCount += expandedDynamicDrawCount;
                    recordDynamicDiagnostic(entityResourceError);
                }
            }

            if (localPlayerVertexCount != 0) {
                std::string playerResourceError;
                const bool playerWasActive = std::find(
                    impl_->activeSerials.begin(), impl_->activeSerials.end(),
                    kLocalPlayerGeometrySerial) != impl_->activeSerials.end();
                id<MTLAccelerationStructure> previous =
                    impl_->localPlayerGeometry.bottomLevel;
                localPlayerBottomLevelBuild = prepareBottomLevel(
                    impl_->localPlayerGeometry, localPlayerVertexOffset,
                    localPlayerVertexCount,
                    @"ShaderMetal Local Player Shadow BLAS",
                    playerResourceError);
                if (localPlayerBottomLevelBuild.has_value()) {
                    impl_->localPlayerGeometry.instanceMask =
                        kLocalPlayerShadowInstanceMask;
                    localPlayerTLASUpdateRequired = !playerWasActive ||
                        previous != impl_->localPlayerGeometry.bottomLevel;
                } else {
                    ++result.skippedDynamicDrawCount;
                    recordDynamicDiagnostic(playerResourceError);
                }
            }

            result.encodedDynamicDrawCount = expandedDynamicDrawCount +
                (localPlayerBottomLevelBuild.has_value() ? 1U : 0U);
            result.dynamicVertexCount = dynamicEntityVertexCount +
                (localPlayerBottomLevelBuild.has_value()
                    ? localPlayerVertexCount : 0U);
            result.dynamicTriangleCount = result.dynamicVertexCount / 3U;
        } else {
            result.skippedDynamicDrawCount += expandedDynamicDrawCount +
                (localPlayerVertexCount != 0 ? 1U : 0U);
            recordDynamicDiagnostic(sharedBufferError);
        }
    }
    if (!dynamicBottomLevelBuild.has_value() &&
        !localPlayerBottomLevelBuild.has_value()) {
        impl_->dynamicCanonicalVertexBuffer = nil;
        impl_->dynamicCanonicalVertexCount = 0;
    }

    std::vector<ActiveInstance> active;
    std::vector<Geometry *> recentlyVisibleTerrain;
    std::vector<GeometryKey> deadGeometryKeys;
    try {
        const std::size_t terrainReserve = std::min(
            impl_->geometries.size(),
            eligibleSerials.size() + std::min(
                kMaximumInvisibleTerrainInstances,
                impl_->geometries.size() -
                    std::min(impl_->geometries.size(), eligibleSerials.size())));
        active.reserve(terrainReserve + 2U);
        recentlyVisibleTerrain.reserve(std::min(
            impl_->geometries.size(), kMaximumInvisibleTerrainInstances * 2U));
        deadGeometryKeys.reserve(32);
        for (const auto &[key, geometryStorage] : impl_->geometries) {
            Geometry &geometry = *geometryStorage;
            const auto observed = impl_->observedInstances.find(geometry.serial);
            const bool visibleTerrain = observed != impl_->observedInstances.end() &&
                eligibleSerials.contains(geometry.serial) &&
                !impl_->excludedThisFrame.contains(geometry.serial) &&
                geometry.lastVisibleFrame == impl_->frameOrdinal;
            if (geometry.state != GeometryState::Ready &&
                geometry.state != GeometryState::Scheduled) {
                if (!visibleTerrain && !geometryBuffersResident(geometry)) {
                    deadGeometryKeys.push_back(key);
                }
                continue;
            }
            if (!geometry.terrainConfirmed ||
                geometry.transformEpoch != impl_->sceneEpoch ||
                impl_->excludedThisFrame.contains(geometry.serial)) {
                continue;
            }

            if (visibleTerrain) {
                active.push_back(ActiveInstance{
                    &geometry, geometry.localToScene,
                    geometry.normalToScene});
                continue;
            }
            if (!geometryBuffersResident(geometry)) {
                deadGeometryKeys.push_back(key);
                continue;
            }
            if (geometry.lastVisibleFrame == 0 ||
                geometry.lastVisibleFrame > impl_->frameOrdinal ||
                impl_->frameOrdinal - geometry.lastVisibleFrame >
                    kInvisibleTerrainRetentionFrames) {
                continue;
            }
            recentlyVisibleTerrain.push_back(&geometry);
        }
        const auto moreRecentlyVisible = [](const Geometry *left,
                                            const Geometry *right) {
            if (left->lastVisibleFrame != right->lastVisibleFrame) {
                return left->lastVisibleFrame > right->lastVisibleFrame;
            }
            return left->serial < right->serial;
        };
        if (recentlyVisibleTerrain.size() >
            kMaximumInvisibleTerrainInstances) {
            std::nth_element(
                recentlyVisibleTerrain.begin(),
                recentlyVisibleTerrain.begin() +
                    kMaximumInvisibleTerrainInstances,
                recentlyVisibleTerrain.end(), moreRecentlyVisible);
            recentlyVisibleTerrain.resize(kMaximumInvisibleTerrainInstances);
        }
        std::sort(recentlyVisibleTerrain.begin(), recentlyVisibleTerrain.end(),
                  moreRecentlyVisible);
        for (Geometry *geometry : recentlyVisibleTerrain) {
            active.push_back(ActiveInstance{
                geometry, geometry->localToScene, geometry->normalToScene});
        }
        result.retainedInvisibleInstanceCount = recentlyVisibleTerrain.size();
        if (dynamicBottomLevelBuild.has_value()) {
            active.push_back(ActiveInstance{
                &impl_->dynamicGeometry, identityMatrix(),
                paddedLinearColumns(identityMatrix())});
        }
        if (localPlayerBottomLevelBuild.has_value()) {
            active.push_back(ActiveInstance{
                &impl_->localPlayerGeometry, identityMatrix(),
                paddedLinearColumns(identityMatrix())});
        }
        std::sort(active.begin(), active.end(), [](const ActiveInstance &left,
                                                   const ActiveInstance &right) {
            return left.geometry->serial < right.geometry->serial;
        });
    } catch (const std::bad_alloc &) {
        error = "unable to assemble active terrain RT instances";
        for (BottomLevelBuild &build : bottomLevelBuilds) {
            build.geometry->state = GeometryState::PendingBuild;
            build.geometry->bottomLevel = nil;
        }
        return result;
    }

    for (const GeometryKey &key : deadGeometryKeys) {
        const auto dead = impl_->geometries.find(key);
        if (dead == impl_->geometries.end()) {
            continue;
        }
        const std::uint64_t serial = dead->second->serial;
        impl_->retireCanonicalRange(*dead->second);
        impl_->observedInstances.erase(serial);
        impl_->excludedThisFrame.erase(serial);
        impl_->geometries.erase(dead);
    }

    std::vector<std::uint64_t> currentSerials;
    std::vector<std::array<float, 16>> currentTransforms;
    std::vector<std::int32_t> currentTextureIds;
    std::vector<std::uint32_t> currentMetadataFlags;
    std::vector<id<MTLAccelerationStructure>> currentBottomLevels;
    try {
        currentSerials.reserve(active.size());
        currentTransforms.reserve(active.size());
        currentTextureIds.reserve(active.size());
        currentMetadataFlags.reserve(active.size());
        currentBottomLevels.reserve(active.size());
        for (const ActiveInstance &instance : active) {
            currentSerials.push_back(instance.geometry->serial);
            currentTransforms.push_back(instance.localToScene);
            currentTextureIds.push_back(instance.geometry->textureId);
            currentMetadataFlags.push_back(instance.geometry->metadataFlags);
            currentBottomLevels.push_back(instance.geometry->bottomLevel);
        }
    } catch (const std::bad_alloc &) {
        error = "unable to compare terrain RT topology";
        for (BottomLevelBuild &build : bottomLevelBuilds) {
            build.geometry->state = GeometryState::PendingBuild;
            build.geometry->bottomLevel = nil;
        }
        return result;
    }

    const bool topologyChanged = currentSerials != impl_->activeSerials ||
                                 currentBottomLevels != impl_->activeBottomLevels ||
                                 (active.empty() ? impl_->topLevel != nil
                                                 : impl_->topLevel == nil);
    const bool transformsChanged = currentTransforms != impl_->activeTransforms;
    const bool materialsChanged =
        currentTextureIds != impl_->activeTextureIds ||
        currentMetadataFlags != impl_->activeMetadataFlags;
    const bool projectionChanged = impl_->observedProjectionValid &&
        impl_->projection != impl_->observedProjection;

    std::optional<TopLevelUpdate> topLevelUpdate;
    if (!active.empty() &&
        (topologyChanged || transformsChanged || materialsChanged ||
         dynamicTLASUpdateRequired || localPlayerTLASUpdateRequired)) {
        TopLevelUpdate update;
        update.rebuild = topologyChanged;
        update.serials = currentSerials;
        update.transforms = currentTransforms;
        update.textureIds = currentTextureIds;
        update.metadataFlags = currentMetadataFlags;
        try {
            update.bottomLevels = currentBottomLevels;
        } catch (const std::bad_alloc &) {
            error = "unable to retain active terrain BLAS resources";
        }

        if (active.size() > std::numeric_limits<std::uint32_t>::max()) {
            error = "terrain TLAS instance count exceeds Metal's 32-bit index range";
        }

        std::size_t descriptorBytes = 0;
        std::size_t metadataBytes = 0;
        if (error.empty() &&
            (!checkedMultiply(active.size(),
                              sizeof(MTLAccelerationStructureUserIDInstanceDescriptor),
                              descriptorBytes) ||
             !checkedMultiply(active.size(), sizeof(RTInstanceMetadata),
                              metadataBytes) ||
             descriptorBytes > std::numeric_limits<NSUInteger>::max() ||
             metadataBytes > std::numeric_limits<NSUInteger>::max())) {
            error = "terrain TLAS instance buffers exceed Metal's size range";
        }

        if (error.empty()) {
            update.instanceDescriptorBuffer = [impl_->device
                newBufferWithLength:static_cast<NSUInteger>(descriptorBytes)
                            options:MTLResourceStorageModeShared];
            update.instanceMetadataBuffer = [impl_->device
                newBufferWithLength:static_cast<NSUInteger>(metadataBytes)
                            options:MTLResourceStorageModeShared];
            if (update.instanceDescriptorBuffer == nil ||
                update.instanceMetadataBuffer == nil ||
                update.instanceDescriptorBuffer.contents == nullptr ||
                update.instanceMetadataBuffer.contents == nullptr) {
                error = "Metal failed to allocate shared terrain TLAS instance buffers";
            }
        }

        if (error.empty()) {
            update.instanceDescriptorBuffer.label =
                @"ShaderMetal RT Instance Descriptors";
            update.instanceMetadataBuffer.label =
                @"ShaderMetal RT Instance Metadata";
            auto *descriptors =
                static_cast<MTLAccelerationStructureUserIDInstanceDescriptor *>(
                    update.instanceDescriptorBuffer.contents);
            auto *metadata = static_cast<RTInstanceMetadata *>(
                update.instanceMetadataBuffer.contents);
            for (std::size_t index = 0; index < active.size(); ++index) {
                const ActiveInstance &instance = active[index];
                const Geometry &geometry = *instance.geometry;
                if (geometry.canonicalVertexOffset >
                        std::numeric_limits<std::uint32_t>::max() ||
                    geometry.canonicalVertexCount >
                        std::numeric_limits<std::uint32_t>::max() ||
                    index > std::numeric_limits<std::uint32_t>::max()) {
                    error = "terrain TLAS instance index exceeds its 32-bit Metal field";
                    break;
                }

                MTLAccelerationStructureUserIDInstanceDescriptor descriptor{};
                descriptor.transformationMatrix = packedTransform(instance.localToScene);
                descriptor.options =
                    MTLAccelerationStructureInstanceOptionDisableTriangleCulling;
                if ((geometry.metadataFlags &
                     (kRTInstanceFlagTranslucent | kRTInstanceFlagAlphaTest |
                      kRTInstanceFlagDynamicVertexBuffer)) == 0U) {
                    descriptor.options |=
                        MTLAccelerationStructureInstanceOptionOpaque;
                }
                descriptor.mask = geometry.instanceMask;
                descriptor.intersectionFunctionTableOffset = 0;
                descriptor.accelerationStructureIndex =
                    static_cast<std::uint32_t>(index);
                descriptor.userID = static_cast<std::uint32_t>(
                    geometry.canonicalVertexOffset);
                descriptors[index] = descriptor;

                RTInstanceMetadata instanceMetadata{};
                std::copy(instance.normalToScene.begin(), instance.normalToScene.end(),
                          instanceMetadata.normalToScene);
                instanceMetadata.canonicalVertexOffset = descriptor.userID;
                instanceMetadata.canonicalVertexCount =
                    static_cast<std::uint32_t>(geometry.canonicalVertexCount);
                instanceMetadata.textureId = geometry.textureId;
                instanceMetadata.flags = geometry.metadataFlags;
                metadata[index] = instanceMetadata;
            }
        }

        if (error.empty()) {
            NSMutableArray<id<MTLAccelerationStructure>> *bottomLevels =
                [NSMutableArray arrayWithCapacity:active.size()];
            for (id<MTLAccelerationStructure> bottomLevel : update.bottomLevels) {
                [bottomLevels addObject:bottomLevel];
            }

            update.descriptor = [MTLInstanceAccelerationStructureDescriptor descriptor];
            update.descriptor.instanceDescriptorBuffer =
                update.instanceDescriptorBuffer;
            update.descriptor.instanceDescriptorBufferOffset = 0;
            update.descriptor.instanceDescriptorStride =
                sizeof(MTLAccelerationStructureUserIDInstanceDescriptor);
            update.descriptor.instanceCount = active.size();
            update.descriptor.instanceDescriptorType =
                MTLAccelerationStructureInstanceDescriptorTypeUserID;
            update.descriptor.instancedAccelerationStructures = bottomLevels;
            update.descriptor.usage = accelerationStructureUsage(true);

            const MTLAccelerationStructureSizes sizes =
                [impl_->device accelerationStructureSizesWithDescriptor:
                    update.descriptor];
            if (update.rebuild) {
                if (sizes.accelerationStructureSize == 0) {
                    error = "Metal reported a zero-sized terrain TLAS";
                } else {
                    update.accelerationStructure = [impl_->device
                        newAccelerationStructureWithSize:
                            sizes.accelerationStructureSize];
                    const NSUInteger scratchLength =
                        std::max<NSUInteger>(sizes.buildScratchBufferSize, 1);
                    update.scratchBuffer = [impl_->device
                        newBufferWithLength:scratchLength
                                    options:MTLResourceStorageModePrivate];
                }
            } else {
                update.accelerationStructure = impl_->topLevel;
                if (sizes.refitScratchBufferSize != 0) {
                    update.scratchBuffer = [impl_->device
                        newBufferWithLength:sizes.refitScratchBufferSize
                                    options:MTLResourceStorageModePrivate];
                }
            }
            if (update.accelerationStructure == nil ||
                (update.rebuild && update.scratchBuffer == nil) ||
                (!update.rebuild && sizes.refitScratchBufferSize != 0 &&
                 update.scratchBuffer == nil)) {
                error = "Metal failed to allocate the terrain TLAS or scratch buffer";
            } else {
                update.accelerationStructure.label = @"ShaderMetal Terrain TLAS";
                if (update.scratchBuffer != nil) {
                    update.scratchBuffer.label = @"ShaderMetal Terrain TLAS Scratch";
                }
            }
        }

        if (error.empty()) {
            topLevelUpdate = std::move(update);
        } else {
            // Never expose a previous-frame TLAS with current-frame transforms
            // or topology after a failed update.
            impl_->topLevel = nil;
            impl_->instanceDescriptorBuffer = nil;
            impl_->instanceMetadataBuffer = nil;
            impl_->activeSerials.clear();
            impl_->activeTransforms.clear();
            impl_->activeTextureIds.clear();
            impl_->activeMetadataFlags.clear();
            impl_->activeBottomLevels.clear();
            ++impl_->generation;
        }
    } else if (active.empty() && topologyChanged) {
        impl_->topLevel = nil;
        impl_->instanceDescriptorBuffer = nil;
        impl_->instanceMetadataBuffer = nil;
        impl_->activeSerials.clear();
        impl_->activeTransforms.clear();
        impl_->activeTextureIds.clear();
        impl_->activeMetadataFlags.clear();
        impl_->activeBottomLevels.clear();
        ++impl_->generation;
    }

    const bool hasAccelerationCommands = !bottomLevelBuilds.empty() ||
                                         dynamicBottomLevelBuild.has_value() ||
                                         localPlayerBottomLevelBuild.has_value() ||
                                         topLevelUpdate.has_value();
    id<MTLAccelerationStructureCommandEncoder> encoder = nil;
    if (hasAccelerationCommands) {
        encoder = [commandBuffer accelerationStructureCommandEncoder];
        if (encoder == nil) {
            if (error.empty()) {
                error = "Metal failed to create an acceleration-structure encoder";
            }
            for (BottomLevelBuild &build : bottomLevelBuilds) {
                build.geometry->state = GeometryState::PendingBuild;
                build.geometry->bottomLevel = nil;
            }
            if (dynamicBottomLevelBuild.has_value()) {
                result.skippedDynamicDrawCount +=
                    result.encodedDynamicDrawCount;
                result.encodedDynamicDrawCount = 0;
                result.dynamicTriangleCount = 0;
                result.dynamicVertexCount = 0;
                impl_->dynamicCanonicalVertexBuffer = nil;
                impl_->dynamicCanonicalVertexCount = 0;
            }
            if (localPlayerBottomLevelBuild.has_value()) {
                result.rebuiltLocalPlayerBottomLevel = false;
                result.refitLocalPlayerBottomLevel = false;
                impl_->dynamicCanonicalVertexBuffer = nil;
                impl_->dynamicCanonicalVertexCount = 0;
            }
            impl_->topLevel = nil;
            impl_->instanceDescriptorBuffer = nil;
            impl_->instanceMetadataBuffer = nil;
            impl_->activeSerials.clear();
            impl_->activeTransforms.clear();
            impl_->activeTextureIds.clear();
            impl_->activeMetadataFlags.clear();
            impl_->activeBottomLevels.clear();
            ++impl_->generation;
            topLevelUpdate.reset();
        }
    }

    if (encoder != nil) {
        encoder.label = @"ShaderMetal Acceleration Structure Updates";
        for (BottomLevelBuild &build : bottomLevelBuilds) {
            [encoder buildAccelerationStructure:build.accelerationStructure
                                     descriptor:build.descriptor
                                  scratchBuffer:build.scratchBuffer
                            scratchBufferOffset:0];
            build.geometry->state = GeometryState::Ready;
            ++result.newBottomLevelBuildCount;
        }
        if (dynamicBottomLevelBuild.has_value()) {
            DynamicBottomLevelBuild &build = *dynamicBottomLevelBuild;
            if (build.refit) {
                [encoder refitAccelerationStructure:build.accelerationStructure
                                             descriptor:build.descriptor
                                            destination:nil
                                          scratchBuffer:build.scratchBuffer
                                    scratchBufferOffset:0];
                result.refitDynamicBottomLevel = true;
            } else {
                [encoder buildAccelerationStructure:build.accelerationStructure
                                         descriptor:build.descriptor
                                      scratchBuffer:build.scratchBuffer
                                scratchBufferOffset:0];
                result.rebuiltDynamicBottomLevel = true;
            }
            impl_->dynamicGeometry.state = GeometryState::Ready;
        }
        if (localPlayerBottomLevelBuild.has_value()) {
            DynamicBottomLevelBuild &build = *localPlayerBottomLevelBuild;
            if (build.refit) {
                [encoder refitAccelerationStructure:build.accelerationStructure
                                             descriptor:build.descriptor
                                            destination:nil
                                          scratchBuffer:build.scratchBuffer
                                    scratchBufferOffset:0];
                result.refitLocalPlayerBottomLevel = true;
            } else {
                [encoder buildAccelerationStructure:build.accelerationStructure
                                         descriptor:build.descriptor
                                      scratchBuffer:build.scratchBuffer
                                scratchBufferOffset:0];
                result.rebuiltLocalPlayerBottomLevel = true;
            }
            impl_->localPlayerGeometry.state = GeometryState::Ready;
        }

        if (topLevelUpdate.has_value()) {
            TopLevelUpdate &update = *topLevelUpdate;
            if (update.rebuild) {
                [encoder buildAccelerationStructure:update.accelerationStructure
                                         descriptor:update.descriptor
                                      scratchBuffer:update.scratchBuffer
                                scratchBufferOffset:0];
                result.rebuiltTopLevel = true;
            } else {
                [encoder refitAccelerationStructure:update.accelerationStructure
                                         descriptor:update.descriptor
                                        destination:nil
                                      scratchBuffer:update.scratchBuffer
                                scratchBufferOffset:0];
                result.refitTopLevel = true;
            }
            const bool dynamicInUpdatedScene = std::find(
                update.serials.begin(), update.serials.end(),
                kDynamicGeometrySerial) != update.serials.end();
            impl_->topLevel = update.accelerationStructure;
            impl_->instanceDescriptorBuffer = update.instanceDescriptorBuffer;
            impl_->instanceMetadataBuffer = update.instanceMetadataBuffer;
            impl_->activeSerials = std::move(update.serials);
            impl_->activeTransforms = std::move(update.transforms);
            impl_->activeTextureIds = std::move(update.textureIds);
            impl_->activeMetadataFlags = std::move(update.metadataFlags);
            impl_->activeBottomLevels = std::move(update.bottomLevels);
            if (dynamicInUpdatedScene && currentDynamicBoundsValid) {
                impl_->dynamicTLASBoundsValid = true;
                impl_->dynamicTLASBoundsMinimum = currentDynamicBoundsMinimum;
                impl_->dynamicTLASBoundsMaximum = currentDynamicBoundsMaximum;
                impl_->dynamicTLASVertexCount =
                    impl_->dynamicGeometry.canonicalVertexCount;
            } else if (!dynamicInUpdatedScene) {
                impl_->dynamicTLASBoundsValid = false;
                impl_->dynamicTLASVertexCount = 0;
            }
            ++impl_->generation;
        }
        [encoder endEncoding];
    }

    if (impl_->observedProjectionValid && projectionChanged) {
        impl_->projection = impl_->observedProjection;
        ++impl_->generation;
    }

    result.activeInstanceCount = impl_->activeSerials.size();
    for (const auto &[serial, observed] : impl_->observedInstances) {
        if (!eligibleSerials.contains(serial)) {
            continue;
        }
        if (observed.geometry->state == GeometryState::PendingExpansion ||
            observed.geometry->state == GeometryState::PendingBuild) {
            ++result.pendingBottomLevelBuildCount;
        }
    }
    result.firstDiagnostic = std::move(firstDiagnostic);
    return result;
}

AccelerationSceneSnapshot AccelStructManager::sceneSnapshot() const {
    std::lock_guard lock(impl_->mutex);
    AccelerationSceneSnapshot snapshot;
    snapshot.topLevel = impl_->topLevel;
    snapshot.canonicalVertices = impl_->canonicalVertexBuffer;
    const bool dynamicActive = std::find(
        impl_->activeSerials.begin(), impl_->activeSerials.end(),
        kDynamicGeometrySerial) != impl_->activeSerials.end();
    const bool localPlayerActive = std::find(
        impl_->activeSerials.begin(), impl_->activeSerials.end(),
        kLocalPlayerGeometrySerial) != impl_->activeSerials.end();
    if (dynamicActive || localPlayerActive) {
        snapshot.dynamicCanonicalVertices =
            impl_->dynamicCanonicalVertexBuffer;
        snapshot.dynamicBottomLevel = dynamicActive
            ? impl_->dynamicGeometry.bottomLevel
            : impl_->localPlayerGeometry.bottomLevel;
        snapshot.dynamicCanonicalVertexCount =
            impl_->dynamicCanonicalVertexCount;
    }
    snapshot.instanceMetadata = impl_->instanceMetadataBuffer;
    snapshot.bottomLevels = impl_->activeBottomLevels;
    snapshot.projection = impl_->projection;
    snapshot.viewToScene = impl_->viewToScene;
    snapshot.worldToSceneLinear = impl_->worldToSceneLinear;
    snapshot.canonicalVertexCount = impl_->canonicalVertexCount;
    snapshot.instanceCount = impl_->activeSerials.size();
    snapshot.generation = impl_->generation;
    return snapshot;
}

void AccelStructManager::close() {
    std::lock_guard lock(impl_->mutex);
    impl_->resetScene();
    impl_->device = nil;
}

} // namespace shadermetal
