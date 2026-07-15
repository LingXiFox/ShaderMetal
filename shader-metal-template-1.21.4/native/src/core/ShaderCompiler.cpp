#include "core/ShaderCompiler.hpp"

#include <SPIRV/GlslangToSpv.h>
#include <glslang/Public/ResourceLimits.h>
#include <glslang/Public/ShaderLang.h>
#include <spirv_msl.hpp>

#include <algorithm>
#include <exception>
#include <limits>
#include <mutex>
#include <string>
#include <utility>

namespace shadermetal {
namespace {

class GlslangRuntime final {
public:
    GlslangRuntime()
        : initialized_(glslang::InitializeProcess()) {
    }

    ~GlslangRuntime() {
        if (initialized_) {
            glslang::FinalizeProcess();
        }
    }

    GlslangRuntime(const GlslangRuntime &) = delete;
    GlslangRuntime &operator=(const GlslangRuntime &) = delete;

    [[nodiscard]] bool initialized() const noexcept {
        return initialized_;
    }

    [[nodiscard]] std::mutex &compileMutex() noexcept {
        return compileMutex_;
    }

private:
    const bool initialized_;
    std::mutex compileMutex_;
};

GlslangRuntime &glslangRuntime() {
    // Function-local static initialization is thread-safe and pairs the process-wide
    // glslang lifetime exactly once, independent of ShaderCompiler call count.
    static GlslangRuntime runtime;
    return runtime;
}

void addDiagnostic(
    ShaderCompilationResult &result,
    ShaderDiagnosticSeverity severity,
    ShaderDiagnosticPhase phase,
    std::string message) {
    if (message.empty()) {
        return;
    }

    result.diagnostics.push_back(ShaderDiagnostic{
        .severity = severity,
        .phase = phase,
        .message = std::move(message),
    });
}

ShaderDiagnosticSeverity classifyLogLine(
    std::string_view line,
    ShaderDiagnosticSeverity fallback) {
    if (line.find("ERROR:") != std::string_view::npos ||
        line.find("INTERNAL ERROR") != std::string_view::npos) {
        return ShaderDiagnosticSeverity::Error;
    }
    if (line.find("WARNING:") != std::string_view::npos) {
        return ShaderDiagnosticSeverity::Warning;
    }
    return fallback;
}

void appendLog(
    ShaderCompilationResult &result,
    ShaderDiagnosticPhase phase,
    const char *log,
    ShaderDiagnosticSeverity fallback) {
    if (log == nullptr || *log == '\0') {
        return;
    }

    std::string_view remaining(log);
    while (!remaining.empty()) {
        const std::size_t newline = remaining.find('\n');
        std::string_view line = remaining.substr(0, newline);
        if (!line.empty() && line.back() == '\r') {
            line.remove_suffix(1);
        }

        const std::size_t first = line.find_first_not_of(" \t");
        if (first != std::string_view::npos) {
            line.remove_prefix(first);
            const std::size_t last = line.find_last_not_of(" \t");
            line = line.substr(0, last + 1);
            addDiagnostic(result, classifyLogLine(line, fallback), phase, std::string(line));
        }

        if (newline == std::string_view::npos) {
            break;
        }
        remaining.remove_prefix(newline + 1);
    }
}

[[nodiscard]] bool hasErrorForPhase(
    const ShaderCompilationResult &result,
    ShaderDiagnosticPhase phase) {
    return std::any_of(
        result.diagnostics.begin(),
        result.diagnostics.end(),
        [phase](const ShaderDiagnostic &diagnostic) {
            return diagnostic.phase == phase &&
                diagnostic.severity == ShaderDiagnosticSeverity::Error;
        });
}

[[nodiscard]] bool toGlslangStage(ShaderStage stage, EShLanguage &language) noexcept {
    switch (stage) {
    case ShaderStage::Vertex:
        language = EShLangVertex;
        return true;
    case ShaderStage::Fragment:
        language = EShLangFragment;
        return true;
    }
    return false;
}

} // namespace

ShaderCompilationResult ShaderCompiler::glslToMsl(
    ShaderStage stage,
    std::string_view source,
    std::string_view sourceName) {
    ShaderCompilationResult result;
    result.stage = stage;

    EShLanguage language = EShLangVertex;
    if (!toGlslangStage(stage, language)) {
        addDiagnostic(
            result,
            ShaderDiagnosticSeverity::Error,
            ShaderDiagnosticPhase::InputValidation,
            "Unsupported shader stage");
        return result;
    }
    if (source.empty()) {
        addDiagnostic(
            result,
            ShaderDiagnosticSeverity::Error,
            ShaderDiagnosticPhase::InputValidation,
            "Shader source is empty");
        return result;
    }
    if (source.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        addDiagnostic(
            result,
            ShaderDiagnosticSeverity::Error,
            ShaderDiagnosticPhase::InputValidation,
            "Shader source exceeds glslang's supported input length");
        return result;
    }

    GlslangRuntime &runtime = glslangRuntime();
    if (!runtime.initialized()) {
        addDiagnostic(
            result,
            ShaderDiagnosticSeverity::Error,
            ShaderDiagnosticPhase::Initialization,
            "glslang process initialization failed");
        return result;
    }

    const std::string sourceStorage(source);
    const std::string sourceNameStorage = sourceName.empty()
        ? std::string("<memory>")
        : std::string(sourceName);

    {
        std::lock_guard<std::mutex> lock(runtime.compileMutex());
        ShaderDiagnosticPhase activePhase = ShaderDiagnosticPhase::Parsing;

        try {
            glslang::TShader shader(language);
            const char *sourcePointer = sourceStorage.c_str();
            const int sourceLength = static_cast<int>(sourceStorage.size());
            const char *sourceNamePointer = sourceNameStorage.c_str();
            shader.setStringsWithLengthsAndNames(
                &sourcePointer,
                &sourceLength,
                &sourceNamePointer,
                1);
            shader.setEnvInput(
                glslang::EShSourceGlsl,
                language,
                glslang::EShClientVulkan,
                100);
            shader.setEnvClient(
                glslang::EShClientVulkan,
                glslang::EShTargetVulkan_1_2);
            shader.setEnvTarget(
                glslang::EShTargetSpv,
                glslang::EShTargetSpv_1_5);
            shader.setAutoMapBindings(true);
            shader.setAutoMapLocations(true);

            const EShMessages messages = static_cast<EShMessages>(
                EShMsgSpvRules | EShMsgVulkanRules | EShMsgEnhanced);
            if (!shader.parse(GetDefaultResources(), 460, false, messages)) {
                appendLog(
                    result,
                    ShaderDiagnosticPhase::Parsing,
                    shader.getInfoLog(),
                    ShaderDiagnosticSeverity::Error);
                appendLog(
                    result,
                    ShaderDiagnosticPhase::Parsing,
                    shader.getInfoDebugLog(),
                    ShaderDiagnosticSeverity::Info);
                if (!hasErrorForPhase(result, ShaderDiagnosticPhase::Parsing)) {
                    addDiagnostic(
                        result,
                        ShaderDiagnosticSeverity::Error,
                        ShaderDiagnosticPhase::Parsing,
                        "glslang rejected the shader source");
                }
                return result;
            }
            appendLog(
                result,
                ShaderDiagnosticPhase::Parsing,
                shader.getInfoLog(),
                ShaderDiagnosticSeverity::Info);
            appendLog(
                result,
                ShaderDiagnosticPhase::Parsing,
                shader.getInfoDebugLog(),
                ShaderDiagnosticSeverity::Info);

            activePhase = ShaderDiagnosticPhase::Linking;
            glslang::TProgram program;
            program.addShader(&shader);
            if (!program.link(messages)) {
                appendLog(
                    result,
                    ShaderDiagnosticPhase::Linking,
                    program.getInfoLog(),
                    ShaderDiagnosticSeverity::Error);
                appendLog(
                    result,
                    ShaderDiagnosticPhase::Linking,
                    program.getInfoDebugLog(),
                    ShaderDiagnosticSeverity::Info);
                if (!hasErrorForPhase(result, ShaderDiagnosticPhase::Linking)) {
                    addDiagnostic(
                        result,
                        ShaderDiagnosticSeverity::Error,
                        ShaderDiagnosticPhase::Linking,
                        "glslang failed to link the shader stage");
                }
                return result;
            }
            appendLog(
                result,
                ShaderDiagnosticPhase::Linking,
                program.getInfoLog(),
                ShaderDiagnosticSeverity::Info);
            appendLog(
                result,
                ShaderDiagnosticPhase::Linking,
                program.getInfoDebugLog(),
                ShaderDiagnosticSeverity::Info);

            const glslang::TIntermediate *intermediate = program.getIntermediate(language);
            if (intermediate == nullptr) {
                addDiagnostic(
                    result,
                    ShaderDiagnosticSeverity::Error,
                    ShaderDiagnosticPhase::Linking,
                    "glslang produced no intermediate representation");
                return result;
            }

            activePhase = ShaderDiagnosticPhase::SpirvGeneration;
            glslang::SpvOptions options;
            options.stripDebugInfo = true;
            options.disableOptimizer = true;

            spv::SpvBuildLogger logger;
            glslang::GlslangToSpv(*intermediate, result.spirv, &logger, &options);
            appendLog(
                result,
                ShaderDiagnosticPhase::SpirvGeneration,
                logger.getAllMessages().c_str(),
                ShaderDiagnosticSeverity::Warning);
            if (result.spirv.empty()) {
                addDiagnostic(
                    result,
                    ShaderDiagnosticSeverity::Error,
                    ShaderDiagnosticPhase::SpirvGeneration,
                    "glslang produced an empty SPIR-V module");
                return result;
            }
        } catch (const std::exception &exception) {
            addDiagnostic(
                result,
                ShaderDiagnosticSeverity::Error,
                activePhase,
                exception.what());
            result.spirv.clear();
            return result;
        } catch (...) {
            addDiagnostic(
                result,
                ShaderDiagnosticSeverity::Error,
                activePhase,
                "Unknown glslang compilation failure");
            result.spirv.clear();
            return result;
        }
    }

    try {
        spirv_cross::CompilerMSL compiler(result.spirv);
        spirv_cross::CompilerGLSL::Options commonOptions = compiler.get_common_options();
        commonOptions.vertex.fixup_clipspace = stage == ShaderStage::Vertex;
        compiler.set_common_options(commonOptions);

        spirv_cross::CompilerMSL::Options options = compiler.get_msl_options();
        options.platform = spirv_cross::CompilerMSL::Options::macOS;
        options.set_msl_version(3, 0);
        options.argument_buffers = true;
        options.argument_buffers_tier =
            spirv_cross::CompilerMSL::Options::ArgumentBuffersTier::Tier2;
        options.force_active_argument_buffer_resources = true;
        compiler.set_msl_options(options);

        // Set 0 is the bindless texture/sampler argument buffer. Keep the
        // per-draw std140 block in set 1 as a direct Metal buffer so JNI can
        // bind copied bytes without constructing a nested argument buffer.
        compiler.set_argument_buffer_device_address_space(0, true);
        compiler.add_discrete_descriptor_set(1);
        spirv_cross::MSLResourceBinding uniformBinding;
        uniformBinding.stage = stage == ShaderStage::Vertex
            ? spv::ExecutionModelVertex
            : spv::ExecutionModelFragment;
        uniformBinding.desc_set = 1;
        uniformBinding.binding = 0;
        uniformBinding.msl_buffer = 1;
        compiler.add_msl_resource_binding(uniformBinding);
        result.msl = compiler.compile();
    } catch (const std::exception &exception) {
        addDiagnostic(
            result,
            ShaderDiagnosticSeverity::Error,
            ShaderDiagnosticPhase::MslGeneration,
            exception.what());
        return result;
    } catch (...) {
        addDiagnostic(
            result,
            ShaderDiagnosticSeverity::Error,
            ShaderDiagnosticPhase::MslGeneration,
            "Unknown SPIRV-Cross compilation failure");
        return result;
    }

    if (result.msl.empty()) {
        addDiagnostic(
            result,
            ShaderDiagnosticSeverity::Error,
            ShaderDiagnosticPhase::MslGeneration,
            "SPIRV-Cross produced empty MSL source");
        return result;
    }

    result.success = true;
    return result;
}

} // namespace shadermetal
