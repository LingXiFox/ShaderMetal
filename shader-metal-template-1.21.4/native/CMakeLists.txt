cmake_minimum_required(VERSION 3.20)

project(shadermetal LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_OSX_ARCHITECTURES "arm64")
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0")

find_package(JNI REQUIRED)

foreach(framework Metal MetalFX Foundation QuartzCore AppKit)
    find_library(${framework}_LIBRARY ${framework} REQUIRED)
endforeach()

# Stage B always requires GLSL -> SPIR-V -> MSL. Keep the vendored builds
# focused on the libraries ShaderMetal actually links so native builds stay
# predictable on developer machines.
set(SPIRV_CROSS_CLI OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_STATIC ON CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_GLSL ON CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_MSL ON CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_HLSL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_CPP OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_REFLECT OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_C_API OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_UTIL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_SKIP_INSTALL ON CACHE BOOL "" FORCE)

set(BUILD_EXTERNAL OFF CACHE BOOL "" FORCE)
set(ENABLE_GLSLANG_BINARIES OFF CACHE BOOL "" FORCE)
set(ENABLE_HLSL OFF CACHE BOOL "" FORCE)
set(ENABLE_OPT OFF CACHE BOOL "" FORCE)
set(ENABLE_PCH OFF CACHE BOOL "" FORCE)
set(ENABLE_SPIRV ON CACHE BOOL "" FORCE)
set(GLSLANG_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(GLSLANG_TESTS OFF CACHE BOOL "" FORCE)

add_subdirectory(third_party/SPIRV-Cross)
add_subdirectory(third_party/glslang)

file(GLOB_RECURSE SHADERMETAL_SOURCES CONFIGURE_DEPENDS
    "src/*.cpp"
    "src/*.mm"
)

add_library(shadermetal SHARED ${SHADERMETAL_SOURCES})

find_program(XXD_EXECUTABLE xxd REQUIRED)
set(RAYTRACE_METAL_SOURCE
    "${CMAKE_CURRENT_SOURCE_DIR}/shaders/RayTrace.metal")
set(RAYTRACE_GENERATED_DIRECTORY
    "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(RAYTRACE_EMBEDDED_SOURCE
    "${RAYTRACE_GENERATED_DIRECTORY}/RayTraceMetal.inc")
add_custom_command(
    OUTPUT "${RAYTRACE_EMBEDDED_SOURCE}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory
        "${RAYTRACE_GENERATED_DIRECTORY}"
    COMMAND "${XXD_EXECUTABLE}" -i -n shadermetal_raytrace_metal
        "${RAYTRACE_METAL_SOURCE}" "${RAYTRACE_EMBEDDED_SOURCE}"
    DEPENDS "${RAYTRACE_METAL_SOURCE}"
    VERBATIM
)
add_custom_target(shadermetal_embed_raytrace_shader
    DEPENDS "${RAYTRACE_EMBEDDED_SOURCE}")
add_dependencies(shadermetal shadermetal_embed_raytrace_shader)
target_include_directories(shadermetal PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${RAYTRACE_GENERATED_DIRECTORY}"
    ${JNI_INCLUDE_DIRS}
)
target_compile_options(shadermetal PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra;-Wpedantic>"
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc;-Wall;-Wextra;-Wpedantic>"
)
target_link_libraries(shadermetal PRIVATE
    ${Metal_LIBRARY}
    ${MetalFX_LIBRARY}
    ${Foundation_LIBRARY}
    ${QuartzCore_LIBRARY}
    ${AppKit_LIBRARY}
    spirv-cross-msl
    glslang
    glslang-default-resource-limits
)

set_target_properties(shadermetal PROPERTIES
    OUTPUT_NAME "shadermetal"
    SUFFIX ".dylib"
)

include(CTest)
if(BUILD_TESTING)
    add_executable(shadermetal_shader_compiler_tests
        tests/ShaderCompilerTests.cpp
        src/core/ShaderCompiler.cpp
    )
    target_include_directories(shadermetal_shader_compiler_tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
    )
    target_compile_options(shadermetal_shader_compiler_tests PRIVATE
        -Wall -Wextra -Wpedantic
    )
    target_link_libraries(shadermetal_shader_compiler_tests PRIVATE
        spirv-cross-msl
        glslang
        glslang-default-resource-limits
    )
    add_test(NAME shadermetal_shader_compiler
        COMMAND shadermetal_shader_compiler_tests)
endif()
