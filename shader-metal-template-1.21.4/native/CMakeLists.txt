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

file(GLOB_RECURSE SHADERMETAL_SOURCES CONFIGURE_DEPENDS
    "src/*.cpp"
    "src/*.mm"
)

add_library(shadermetal SHARED ${SHADERMETAL_SOURCES})
target_include_directories(shadermetal PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
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
)

option(SHADERMETAL_BUILD_SHADER_TOOLCHAIN
    "Build the stage B glslang and SPIRV-Cross toolchain" OFF)
if(SHADERMETAL_BUILD_SHADER_TOOLCHAIN)
    add_subdirectory(third_party/SPIRV-Cross)
    add_subdirectory(third_party/glslang)
    target_link_libraries(shadermetal PRIVATE spirv-cross-msl glslang)
endif()

set_target_properties(shadermetal PROPERTIES
    OUTPUT_NAME "shadermetal"
    SUFFIX ".dylib"
)
