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

- (BOOL)acceptsFirstResponder {
    return NO;
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
    bool displaySyncEnabled = true;
    {
        std::lock_guard lock(mutex_);
        if (initialized_) {
            return true;
        }
        displaySyncEnabled = displaySyncEnabled_;
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
    if (device.argumentBuffersSupport != MTLArgumentBuffersTier2) {
        error = "ShaderMetal requires Metal argument buffers tier 2";
        return false;
    }
    if (!device.supportsRaytracing) {
        error = "ShaderMetal Stage C requires hardware Metal ray tracing";
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
    __block CGSize initialDrawableSize = CGSizeMake(1.0, 1.0);
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
        metalLayer.displaySyncEnabled = displaySyncEnabled ? YES : NO;
        metalLayer.contentsScale = window.backingScaleFactor;
        metalLayer.opaque = YES;

        metalView = [[ShaderMetalPassthroughView alloc] initWithFrame:contentView.bounds];
        metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        metalView.wantsLayer = YES;
        metalView.layer = metalLayer;
        metalLayer.frame = metalView.bounds;
        NSResponder *previousFirstResponder = window.firstResponder;
        initialDrawableSize = CGSizeMake(
            std::max(1.0, std::round(contentView.bounds.size.width)),
            std::max(1.0, std::round(contentView.bounds.size.height)));
        metalLayer.drawableSize = initialDrawableSize;
        [contentView addSubview:metalView positioned:NSWindowAbove relativeTo:nil];
        if (window.firstResponder != previousFirstResponder) {
            [window makeFirstResponder:previousFirstResponder];
        }
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
    NSLog(@"[ShaderMetal] Hardware ray tracing: supported");
    NSLog(@"[ShaderMetal] Initial drawable size: %.0fx%.0f",
          initialDrawableSize.width, initialDrawableSize.height);
    NSLog(@"[ShaderMetal] Metal display sync %s",
          displaySyncEnabled ? "enabled" : "disabled");
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

void MetalDevice::setDisplaySyncEnabled(bool enabled) {
    CAMetalLayer *metalLayer = nil;
    {
        std::lock_guard lock(mutex_);
        displaySyncEnabled_ = enabled;
        metalLayer = layer_;
    }

    if (metalLayer == nil) {
        return;
    }

    __block bool changed = false;
    runOnMainThreadSync(^{
        const BOOL requestedValue = enabled ? YES : NO;
        if (metalLayer.displaySyncEnabled != requestedValue) {
            metalLayer.displaySyncEnabled = requestedValue;
            changed = true;
        }
    });
    if (changed) {
        NSLog(@"[ShaderMetal] Metal display sync %s", enabled ? "enabled" : "disabled");
    }
}

void MetalDevice::resize(std::size_t framebufferWidth,
                         std::size_t framebufferHeight) {
    if (framebufferWidth == 0 || framebufferHeight == 0) {
        return;
    }

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

        // macOS can temporarily report the unscaled fullscreen backing size
        // while a screenshot tool or another app owns focus. Rebuilding the
        // ray-tracing and MetalFX targets for that inactive-only transition
        // causes a multi-frame stall, then immediately rebuilds them again on
        // focus return. A real interactive resize is delivered while the game
        // is active and key.
        if (!NSApp.isActive || !window.isKeyWindow) {
            return;
        }

        NSResponder *currentFirstResponder = window.firstResponder;
        if (currentFirstResponder == nil || currentFirstResponder == metalView ||
            currentFirstResponder == window) {
            [window makeFirstResponder:container];
        }

        if (!NSEqualRects(metalView.frame, container.bounds)) {
            metalView.frame = container.bounds;
        }
        metalLayer.frame = metalView.bounds;
        metalLayer.contentsScale = window.backingScaleFactor;

        const CGSize drawableSize = CGSizeMake(
            static_cast<CGFloat>(framebufferWidth),
            static_cast<CGFloat>(framebufferHeight));
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
