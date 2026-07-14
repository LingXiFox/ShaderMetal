#pragma once

#import <AppKit/AppKit.h>

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace shadermetal {

class GlfwBridge final {
public:
    static GlfwBridge &shared();

    bool initialize(const std::vector<std::string> &libraryCandidates, std::string &error);
    NSWindow *cocoaWindow(std::uintptr_t glfwWindowHandle, std::string &error) const;
    void close();

    GlfwBridge(const GlfwBridge &) = delete;
    GlfwBridge &operator=(const GlfwBridge &) = delete;

private:
    using GetCocoaWindowFunction = NSWindow *(*)(void *);

    GlfwBridge() = default;
    ~GlfwBridge();

    mutable std::mutex mutex_;
    void *libraryHandle_ = nullptr;
    GetCocoaWindowFunction getCocoaWindow_ = nullptr;
    std::string libraryPath_;
};

} // namespace shadermetal
