#include "core/ShaderCompiler.hpp"

#include <atomic>
#include <cstdint>
#include <iostream>
#include <string_view>
#include <thread>
#include <vector>

namespace {

using shadermetal::ShaderCompilationResult;
using shadermetal::ShaderCompiler;
using shadermetal::ShaderDiagnosticPhase;
using shadermetal::ShaderDiagnosticSeverity;
using shadermetal::ShaderStage;

constexpr std::string_view kVertexSource = R"(
#version 460 core
layout(location = 0) in vec3 position;
layout(location = 0) out vec3 vertexColor;

void main() {
    gl_Position = vec4(position, 1.0);
    vertexColor = position * 0.5 + 0.5;
}
)";

constexpr std::string_view kFragmentSource = R"(
#version 460 core
layout(location = 0) in vec3 vertexColor;
layout(location = 0) out vec4 fragmentColor;

void main() {
    fragmentColor = vec4(vertexColor, 1.0);
}
)";

int failureCount = 0;

void expect(bool condition, std::string_view description) {
    if (!condition) {
        ++failureCount;
        std::cerr << "FAIL: " << description << '\n';
    }
}

bool hasDiagnostic(
    const ShaderCompilationResult &result,
    ShaderDiagnosticPhase phase,
    ShaderDiagnosticSeverity severity) {
    for (const auto &diagnostic : result.diagnostics) {
        if (diagnostic.phase == phase && diagnostic.severity == severity) {
            return true;
        }
    }
    return false;
}

bool hasDiagnosticMessage(
    const ShaderCompilationResult &result,
    ShaderDiagnosticPhase phase,
    std::string_view text) {
    for (const auto &diagnostic : result.diagnostics) {
        if (diagnostic.phase == phase &&
            diagnostic.message.find(text) != std::string::npos) {
            return true;
        }
    }
    for (const auto &diagnostic : result.diagnostics) {
        if (diagnostic.phase == phase) {
            std::cerr << "DIAGNOSTIC: " << diagnostic.message << '\n';
        }
    }
    return false;
}

void testConcurrentFirstUse() {
    constexpr int threadCount = 4;
    std::atomic<int> successCount = 0;
    std::vector<std::thread> threads;
    threads.reserve(threadCount);

    for (int index = 0; index < threadCount; ++index) {
        threads.emplace_back([index, &successCount] {
            const ShaderStage stage = index % 2 == 0
                ? ShaderStage::Vertex
                : ShaderStage::Fragment;
            const std::string_view source = stage == ShaderStage::Vertex
                ? kVertexSource
                : kFragmentSource;
            const ShaderCompilationResult result = ShaderCompiler::glslToMsl(
                stage,
                source,
                stage == ShaderStage::Vertex ? "concurrent.vert" : "concurrent.frag");
            if (result.success) {
                ++successCount;
            }
        });
    }

    for (std::thread &thread : threads) {
        thread.join();
    }

    expect(successCount == threadCount, "concurrent first use compiles every shader");
}

void testValidVertexShader() {
    const ShaderCompilationResult result = ShaderCompiler::glslToMsl(
        ShaderStage::Vertex,
        kVertexSource,
        "valid.vert");

    expect(result.success, "valid vertex shader succeeds");
    expect(!result.spirv.empty(), "valid vertex shader produces SPIR-V");
    expect(
        !result.spirv.empty() && result.spirv.front() == UINT32_C(0x07230203),
        "vertex SPIR-V has the standard magic number");
    expect(result.msl.find("vertex ") != std::string::npos, "vertex MSL has a vertex entry point");
    expect(result.msl.find("main0") != std::string::npos, "vertex MSL has the translated main entry point");
    expect(
        result.msl.find("Adjust clip-space for Metal") != std::string::npos,
        "vertex MSL converts OpenGL clip depth to Metal clip depth");
}

void testValidFragmentShader() {
    const ShaderCompilationResult result = ShaderCompiler::glslToMsl(
        ShaderStage::Fragment,
        kFragmentSource,
        "valid.frag");

    expect(result.success, "valid fragment shader succeeds");
    expect(!result.spirv.empty(), "valid fragment shader produces SPIR-V");
    expect(result.msl.find("fragment ") != std::string::npos, "fragment MSL has a fragment entry point");
    expect(result.msl.find("main0") != std::string::npos, "fragment MSL has the translated main entry point");
    expect(
        result.msl.find("Adjust clip-space for Metal") == std::string::npos,
        "fragment MSL does not receive vertex clip-space fixup");
}

void testSyntaxError() {
    constexpr std::string_view source = R"(
#version 460 core
layout(location = 0) out vec4 fragmentColor
void main() {
    fragmentColor = vec4(1.0);
}
)";

    const ShaderCompilationResult result = ShaderCompiler::glslToMsl(
        ShaderStage::Fragment,
        source,
        "syntax-error.frag");

    expect(!result.success, "syntax error fails compilation");
    expect(result.spirv.empty(), "syntax error produces no SPIR-V");
    expect(result.msl.empty(), "syntax error produces no MSL");
    expect(
        hasDiagnostic(
            result,
            ShaderDiagnosticPhase::Parsing,
            ShaderDiagnosticSeverity::Error),
        "syntax error reports a structured parsing diagnostic");
}

void testStageMismatch() {
    constexpr std::string_view fragmentOnlySource = R"(
#version 460 core
void main() {
    discard;
}
)";

    const ShaderCompilationResult result = ShaderCompiler::glslToMsl(
        ShaderStage::Vertex,
        fragmentOnlySource,
        "stage-mismatch.vert");

    expect(!result.success, "fragment-only source fails as a vertex shader");
    expect(
        hasDiagnostic(
            result,
            ShaderDiagnosticPhase::Parsing,
            ShaderDiagnosticSeverity::Error),
        "stage mismatch reports a structured parsing diagnostic");
}

void testFixedBindlessArgumentBuffer() {
    constexpr std::string_view source = R"(
#version 460 core
#extension GL_EXT_nonuniform_qualifier : require
layout(location = 0) flat in uint textureIndex;
layout(location = 1) in vec2 textureCoordinates;
layout(location = 0) out vec4 fragmentColor;
layout(set = 0, binding = 0) uniform sampler2D textures[16];

void main() {
    fragmentColor = texture(
        textures[nonuniformEXT(textureIndex)],
        textureCoordinates);
}
)";

    const ShaderCompilationResult result = ShaderCompiler::glslToMsl(
        ShaderStage::Fragment,
        source,
        "fixed-bindless.frag");

    expect(result.success, "fixed-size bindless sampler array compiles");
    expect(
        result.msl.find("spvDescriptorSetBuffer0") != std::string::npos,
        "fixed-size bindless sampler array emits an argument buffer");
    expect(
        result.msl.find("[[id(") != std::string::npos,
        "argument buffer resources have Metal id attributes");
}

void testBindlessAndUniformBindingAbi() {
    constexpr std::string_view source = R"(
#version 460 core
#extension GL_EXT_nonuniform_qualifier : require
layout(location = 0) in vec2 textureCoordinates;
layout(location = 0) out vec4 fragmentColor;
layout(set = 0, binding = 0) uniform sampler2D textures[16];
layout(std140, set = 1, binding = 0) uniform Uniforms {
    vec4 tint;
} uniforms;

void main() {
    fragmentColor = texture(textures[nonuniformEXT(1)], textureCoordinates) * uniforms.tint;
}
)";

    const ShaderCompilationResult result = ShaderCompiler::glslToMsl(
        ShaderStage::Fragment,
        source,
        "binding-abi.frag");

    expect(result.success, "bindless texture and direct uniform ABI compiles");
    expect(
        result.msl.find("[[buffer(0)]]") != std::string::npos,
        "descriptor set 0 uses Metal argument buffer index 0");
    expect(
        result.msl.find("[[buffer(1)]]") != std::string::npos,
        "descriptor set 1 uniform uses direct Metal buffer index 1");
}

void testRuntimeBindlessDiagnostic() {
    constexpr std::string_view source = R"(
#version 460 core
#extension GL_EXT_nonuniform_qualifier : require
layout(location = 0) flat in uint textureIndex;
layout(location = 1) in vec2 textureCoordinates;
layout(location = 0) out vec4 fragmentColor;
layout(set = 0, binding = 0) uniform sampler2D textures[];

void main() {
    fragmentColor = texture(
        textures[nonuniformEXT(textureIndex)],
        textureCoordinates);
}
)";

    const ShaderCompilationResult result = ShaderCompiler::glslToMsl(
        ShaderStage::Fragment,
        source,
        "runtime-bindless.frag");

    expect(!result.success, "runtime combined sampler array fails without a fixed resource count");
    expect(
        hasDiagnostic(
            result,
            ShaderDiagnosticPhase::MslGeneration,
            ShaderDiagnosticSeverity::Error),
        "runtime combined sampler array reports a structured MSL diagnostic");
    expect(
        hasDiagnosticMessage(
            result,
            ShaderDiagnosticPhase::MslGeneration,
            "runtime array currently not supported for combined image sampler"),
        "runtime sampler diagnostic explains the fixed SPIRV-Cross limitation");
}

} // namespace

int main() {
    testConcurrentFirstUse();
    testValidVertexShader();
    testValidFragmentShader();
    testSyntaxError();
    testStageMismatch();
    testFixedBindlessArgumentBuffer();
    testBindlessAndUniformBindingAbi();
    testRuntimeBindlessDiagnostic();

    if (failureCount != 0) {
        std::cerr << failureCount << " shader compiler test(s) failed\n";
        return 1;
    }

    std::cout << "All ShaderCompiler tests passed\n";
    return 0;
}
