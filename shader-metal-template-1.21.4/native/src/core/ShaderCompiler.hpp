#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace shadermetal {

enum class ShaderStage : std::uint8_t {
    Vertex,
    Fragment,
};

enum class ShaderDiagnosticSeverity : std::uint8_t {
    Info,
    Warning,
    Error,
};

enum class ShaderDiagnosticPhase : std::uint8_t {
    InputValidation,
    Initialization,
    Parsing,
    Linking,
    SpirvGeneration,
    MslGeneration,
};

struct ShaderDiagnostic final {
    ShaderDiagnosticSeverity severity = ShaderDiagnosticSeverity::Error;
    ShaderDiagnosticPhase phase = ShaderDiagnosticPhase::InputValidation;
    std::string message;
};

struct ShaderCompilationResult final {
    bool success = false;
    ShaderStage stage = ShaderStage::Vertex;
    std::vector<std::uint32_t> spirv;
    std::string msl;
    std::vector<ShaderDiagnostic> diagnostics;
};

class ShaderCompiler final {
public:
    [[nodiscard]] static ShaderCompilationResult glslToMsl(
        ShaderStage stage,
        std::string_view source,
        std::string_view sourceName = "<memory>");

    ShaderCompiler() = delete;
};

} // namespace shadermetal
