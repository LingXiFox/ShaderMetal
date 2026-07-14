#pragma once

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <mutex>
#include <string>

namespace shadermetal {

class MetalDevice final {
public:
    static MetalDevice &shared();

    bool initialize(NSWindow *window, std::string &error);
    bool isInitialized() const;
    id<MTLDevice> device() const;
    id<MTLCommandQueue> commandQueue() const;
    CAMetalLayer *layer() const;
    void resize();
    void close();

    MetalDevice(const MetalDevice &) = delete;
    MetalDevice &operator=(const MetalDevice &) = delete;

private:
    MetalDevice() = default;
    ~MetalDevice() = default;

    mutable std::mutex mutex_;
    bool initialized_ = false;
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> commandQueue_ = nil;
    NSWindow *window_ = nil;
    NSView *metalView_ = nil;
    CAMetalLayer *layer_ = nil;
};

} // namespace shadermetal
