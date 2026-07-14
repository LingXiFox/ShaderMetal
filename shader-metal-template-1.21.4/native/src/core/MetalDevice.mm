#include "core/MetalDevice.hpp"

#include <algorithm>
#include <cmath>

@interface ShaderMetalPassthroughView : NSView
@end

@implementation ShaderMetalPassthroughView

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (BOOL)isOpaque {
    return YES;
}

@end

namespace shadermetal {
namespace {

void runOnMainThreadSync(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), block);
}

} // namespace

MetalDevice &MetalDevice::shared() {
    static MetalDevice metalDevice;
    return metalDevice;
}

bool MetalDevice::initialize(NSWindow *window, std::string &error) {
    {
        std::lock_guard lock(mutex_);
        if (initialized_) {
            return true;
        }
    }
    if (window == nil) {
        error = "cannot install Metal layer without an NSWindow";
        return false;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
        error = "MTLCreateSystemDefaultDevice returned nil";
        return false;
    }
    id<MTLCommandQueue> commandQueue = [device newCommandQueue];
    if (commandQueue == nil) {
        error = "unable to create the Metal command queue";
        return false;
    }
    commandQueue.label = @"ShaderMetal Command Queue";

    __block ShaderMetalPassthroughView *metalView = nil;
    __block CAMetalLayer *metalLayer = nil;
    __block NSString *installationError = nil;
    runOnMainThreadSync(^{
        NSView *contentView = window.contentView;
        if (contentView == nil) {
            installationError = @"GLFW NSWindow has no contentView";
            return;
        }

        metalLayer = [CAMetalLayer layer];
        metalLayer.device = device;
        metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metalLayer.framebufferOnly = YES;
        metalLayer.maximumDrawableCount = 3;
        metalLayer.allowsNextDrawableTimeout = YES;
        metalLayer.drawableSize = CGSizeMake(1280.0, 720.0);
        metalLayer.contentsScale = window.backingScaleFactor;
        metalLayer.opaque = YES;

        metalView = [[ShaderMetalPassthroughView alloc] initWithFrame:contentView.bounds];
        metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        metalView.wantsLayer = YES;
        metalView.layer = metalLayer;
        metalLayer.frame = metalView.bounds;
        [contentView addSubview:metalView positioned:NSWindowAbove relativeTo:nil];
    });

    if (installationError != nil || metalView == nil || metalLayer == nil) {
        error = installationError != nil
            ? installationError.UTF8String
            : "unable to install the Metal passthrough view";
        return false;
    }

    {
        std::lock_guard lock(mutex_);
        initialized_ = true;
        device_ = device;
        commandQueue_ = commandQueue;
        window_ = window;
        metalView_ = metalView;
        layer_ = metalLayer;
    }

    NSLog(@"[ShaderMetal] Metal initialized on GPU: %@", device.name);
    NSLog(@"[ShaderMetal] Initial drawable size: 1280x720");
    return true;
}

bool MetalDevice::isInitialized() const {
    std::lock_guard lock(mutex_);
    return initialized_;
}

id<MTLDevice> MetalDevice::device() const {
    std::lock_guard lock(mutex_);
    return device_;
}

id<MTLCommandQueue> MetalDevice::commandQueue() const {
    std::lock_guard lock(mutex_);
    return commandQueue_;
}

CAMetalLayer *MetalDevice::layer() const {
    std::lock_guard lock(mutex_);
    return layer_;
}

void MetalDevice::resize() {
    NSWindow *window = nil;
    NSView *metalView = nil;
    CAMetalLayer *metalLayer = nil;
    {
        std::lock_guard lock(mutex_);
        if (!initialized_) {
            return;
        }
        window = window_;
        metalView = metalView_;
        metalLayer = layer_;
    }

    runOnMainThreadSync(^{
        NSView *container = metalView.superview;
        if (container == nil) {
            return;
        }

        if (!NSEqualRects(metalView.frame, container.bounds)) {
            metalView.frame = container.bounds;
        }
        metalLayer.frame = metalView.bounds;
        metalLayer.contentsScale = window.backingScaleFactor;

        const NSRect backingBounds = [metalView convertRectToBacking:metalView.bounds];
        const CGSize drawableSize = CGSizeMake(
            std::max(1.0, std::round(backingBounds.size.width)),
            std::max(1.0, std::round(backingBounds.size.height)));
        if (!CGSizeEqualToSize(metalLayer.drawableSize, drawableSize)) {
            metalLayer.drawableSize = drawableSize;
            NSLog(@"[ShaderMetal] Drawable resized to %.0fx%.0f",
                  drawableSize.width, drawableSize.height);
        }
    });
}

void MetalDevice::close() {
    NSView *metalView = nil;
    {
        std::lock_guard lock(mutex_);
        if (!initialized_ && metalView_ == nil) {
            return;
        }

        initialized_ = false;
        metalView = metalView_;
        layer_ = nil;
        metalView_ = nil;
        window_ = nil;
        commandQueue_ = nil;
        device_ = nil;
    }

    if (metalView != nil) {
        runOnMainThreadSync(^{
            [metalView removeFromSuperview];
            metalView.layer = nil;
            metalView.wantsLayer = NO;
        });
    }
    NSLog(@"[ShaderMetal] Metal renderer closed");
}

} // namespace shadermetal
