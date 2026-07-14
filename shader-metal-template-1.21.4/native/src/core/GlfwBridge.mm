#include "core/GlfwBridge.hpp"

#include <dlfcn.h>
#include <mach-o/dyld.h>

#include <algorithm>
#include <sstream>
#include <utility>

namespace shadermetal {
namespace {

std::string baseName(const std::string &path) {
    const std::size_t separator = path.find_last_of('/');
    return separator == std::string::npos ? path : path.substr(separator + 1);
}

std::vector<std::string> candidateBaseNames(
    const std::vector<std::string> &libraryCandidates) {
    std::vector<std::string> candidates;
    candidates.reserve(libraryCandidates.size() + 2);

    const auto appendUnique = [&candidates](const std::string &candidate) {
        const std::string name = baseName(candidate);
        if (!name.empty()
            && std::find(candidates.begin(), candidates.end(), name) == candidates.end()) {
            candidates.push_back(name);
        }
    };

    for (const std::string &candidate : libraryCandidates) {
        appendUnique(candidate);
    }
    appendUnique("libglfw.dylib");
    appendUnique("libglfw_async.dylib");
    return candidates;
}

std::vector<std::string> loadedImagePaths() {
    std::vector<std::string> paths;
    const std::uint32_t imageCount = _dyld_image_count();
    paths.reserve(imageCount);
    for (std::uint32_t index = 0; index < imageCount; ++index) {
        const char *imageName = _dyld_get_image_name(index);
        if (imageName != nullptr && imageName[0] != '\0') {
            paths.emplace_back(imageName);
        }
    }
    return paths;
}

std::string join(const std::vector<std::string> &values) {
    std::ostringstream stream;
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index != 0) {
            stream << ", ";
        }
        stream << values[index];
    }
    return stream.str();
}

} // namespace

GlfwBridge &GlfwBridge::shared() {
    static GlfwBridge bridge;
    return bridge;
}

GlfwBridge::~GlfwBridge() {
    close();
}

bool GlfwBridge::initialize(const std::vector<std::string> &libraryCandidates,
                            std::string &error) {
    std::lock_guard lock(mutex_);
    if (libraryHandle_ != nullptr && getCocoaWindow_ != nullptr) {
        return true;
    }

    const std::vector<std::string> candidates = candidateBaseNames(libraryCandidates);
    const std::vector<std::string> images = loadedImagePaths();
    std::string lastLoaderError;

    // The JVM has already loaded GLFW. Reusing dyld's resolved path avoids a second GLFW instance.
    for (const std::string &candidate : candidates) {
        for (const std::string &imagePath : images) {
            if (baseName(imagePath) != candidate) {
                continue;
            }

            dlerror();
            void *handle = dlopen(
                imagePath.c_str(), RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD | RTLD_FIRST);
            if (handle == nullptr) {
                const char *loaderError = dlerror();
                lastLoaderError = loaderError != nullptr ? loaderError : "unknown dlopen error";
                continue;
            }

            dlerror();
            void *symbol = dlsym(handle, "glfwGetCocoaWindow");
            const char *symbolError = dlerror();
            if (symbol == nullptr || symbolError != nullptr) {
                lastLoaderError = symbolError != nullptr
                    ? symbolError
                    : "glfwGetCocoaWindow resolved to null";
                dlclose(handle);
                continue;
            }

            libraryHandle_ = handle;
            getCocoaWindow_ = reinterpret_cast<GetCocoaWindowFunction>(symbol);
            libraryPath_ = imagePath;
            NSLog(@"[ShaderMetal] Resolved glfwGetCocoaWindow from %s",
                  libraryPath_.c_str());
            return true;
        }
    }

    error = "no loaded GLFW image matched [" + join(candidates) + "]";
    if (!lastLoaderError.empty()) {
        error += ": " + lastLoaderError;
    }
    return false;
}

NSWindow *GlfwBridge::cocoaWindow(std::uintptr_t glfwWindowHandle, std::string &error) const {
    GetCocoaWindowFunction function = nullptr;
    {
        std::lock_guard lock(mutex_);
        function = getCocoaWindow_;
    }

    if (function == nullptr) {
        error = "GLFW bridge is not initialized";
        return nil;
    }
    if (glfwWindowHandle == 0) {
        error = "GLFW window handle is null";
        return nil;
    }

    NSWindow *window = function(reinterpret_cast<void *>(glfwWindowHandle));
    if (window == nil || ![window isKindOfClass:[NSWindow class]]) {
        error = "glfwGetCocoaWindow did not return an NSWindow";
        return nil;
    }
    return window;
}

void GlfwBridge::close() {
    void *handle = nullptr;
    {
        std::lock_guard lock(mutex_);
        handle = libraryHandle_;
        libraryHandle_ = nullptr;
        getCocoaWindow_ = nullptr;
        libraryPath_.clear();
    }
    if (handle != nullptr) {
        dlclose(handle);
    }
}

} // namespace shadermetal
