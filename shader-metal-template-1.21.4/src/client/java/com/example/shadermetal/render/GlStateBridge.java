package com.example.shadermetal.render;

import com.example.shadermetal.ShaderMetalClient;
import com.example.shadermetal.proxy.PipelineStateProxy;
import com.example.shadermetal.proxy.RendererProxy;

public final class GlStateBridge {
    private static final int GL_TEXTURE0 = 0x84c0;
    private static final int[] BOUND_TEXTURES = new int[32];

    private static int activeTextureUnit;
    private static int polygonMode;

    private GlStateBridge() {
    }

    public static void activeTexture(int textureUnit) {
        activeTextureUnit = Math.max(0, Math.min(BOUND_TEXTURES.length - 1,
            textureUnit - GL_TEXTURE0));
    }

    public static void bindTexture(int textureId) {
        BOUND_TEXTURES[activeTextureUnit] = textureId;
        TextureBridge.registerGeneratedTexture(textureId);
    }

    public static int boundTexture() {
        return BOUND_TEXTURES[activeTextureUnit];
    }

    public static void setBlendEnabled(boolean enabled) {
        ifLoaded(() -> PipelineStateProxy.setBlendEnable(enabled));
    }

    public static void setBlendFunction(int source, int destination) {
        int sourceFactor = blendFactor(source);
        int destinationFactor = blendFactor(destination);
        ifLoaded(() -> PipelineStateProxy.vkSetBlendFuncSeparate(sourceFactor,
            sourceFactor, destinationFactor, destinationFactor));
    }

    public static void setBlendFunctionSeparate(int sourceColor, int destinationColor,
        int sourceAlpha, int destinationAlpha) {
        int sourceColorFactor = blendFactor(sourceColor);
        int sourceAlphaFactor = blendFactor(sourceAlpha);
        int destinationColorFactor = blendFactor(destinationColor);
        int destinationAlphaFactor = blendFactor(destinationAlpha);
        ifLoaded(() -> PipelineStateProxy.vkSetBlendFuncSeparate(sourceColorFactor,
            sourceAlphaFactor, destinationColorFactor, destinationAlphaFactor));
    }

    public static void setBlendEquation(int equation) {
        int operation = blendOperation(equation);
        ifLoaded(() -> PipelineStateProxy.vkSetBlendOpSeparate(operation, operation));
    }

    public static void setColorMask(boolean red, boolean green, boolean blue,
        boolean alpha) {
        int mask = (red ? 1 : 0) | (green ? 2 : 0) | (blue ? 4 : 0) | (alpha ? 8 : 0);
        ifLoaded(() -> PipelineStateProxy.vkSetColorWriteMask(mask));
    }

    public static void setColorLogicEnabled(boolean enabled) {
        ifLoaded(() -> PipelineStateProxy.setColorLogicOpEnable(enabled));
    }

    public static void setColorLogicOperation(int operation) {
        int vkOperation = logicOperation(operation);
        ifLoaded(() -> PipelineStateProxy.vkSetColorLogicOp(vkOperation));
    }

    public static void setDepthTestEnabled(boolean enabled) {
        ifLoaded(() -> PipelineStateProxy.setDepthTestEnable(enabled));
    }

    public static void setDepthWriteEnabled(boolean enabled) {
        ifLoaded(() -> PipelineStateProxy.setDepthWriteEnable(enabled));
    }

    public static void setDepthFunction(int function) {
        int operation = compareOperation(function);
        ifLoaded(() -> PipelineStateProxy.vkSetDepthCompareOp(operation));
    }

    public static void setStencilTestEnabled(boolean enabled) {
        ifLoaded(() -> PipelineStateProxy.setStencilTestEnable(enabled));
    }

    public static void setStencilFunction(int function, int reference, int mask) {
        int operation = compareOperation(function);
        ifLoaded(() -> {
            PipelineStateProxy.vkSetStencilFrontFunc(operation, reference, mask);
            PipelineStateProxy.vkSetStencilBackFunc(operation, reference, mask);
        });
    }

    public static void setStencilOperation(int stencilFail, int depthFail, int pass) {
        int vkStencilFail = stencilOperation(stencilFail);
        int vkDepthFail = stencilOperation(depthFail);
        int vkPass = stencilOperation(pass);
        ifLoaded(() -> {
            PipelineStateProxy.vkSetStencilFrontOp(vkStencilFail, vkDepthFail, vkPass);
            PipelineStateProxy.vkSetStencilBackOp(vkStencilFail, vkDepthFail, vkPass);
        });
    }

    public static void setStencilWriteMask(int mask) {
        ifLoaded(() -> {
            PipelineStateProxy.vkSetStencilFrontWriteMask(mask);
            PipelineStateProxy.vkSetStencilBackWriteMask(mask);
        });
    }

    public static void setCullEnabled(boolean enabled) {
        ifLoaded(() -> PipelineStateProxy.vkSetCullMode(enabled ? 2 : 0));
    }

    public static void setScissorEnabled(boolean enabled) {
        ifLoaded(() -> PipelineStateProxy.setScissorEnabled(enabled));
    }

    public static void setScissor(int x, int y, int width, int height) {
        ifLoaded(() -> PipelineStateProxy.setScissor(x, y, width, height));
    }

    public static void setViewport(int x, int y, int width, int height) {
        ifLoaded(() -> PipelineStateProxy.setViewport(x, y, width, height));
    }

    public static void setPolygonMode(int glMode) {
        polygonMode = polygonMode(glMode);
        ifLoaded(() -> PipelineStateProxy.vkSetPolygonMode(polygonMode));
    }

    public static void setPolygonOffsetEnabled(boolean enabled) {
        ifLoaded(() -> PipelineStateProxy.vkSetDepthBiasEnable(polygonMode, enabled));
    }

    public static void setPolygonOffset(float factor, float units) {
        ifLoaded(() -> PipelineStateProxy.vkSetDepthBias(factor, units));
    }

    public static void setLineWidth(float width) {
        ifLoaded(() -> PipelineStateProxy.setLineWidth(width));
    }

    public static void setClearColor(float red, float green, float blue, float alpha) {
        ifLoaded(() -> RendererProxy.setClearColor(red, green, blue, alpha));
    }

    public static void setClearDepth(double depth) {
        ifLoaded(() -> RendererProxy.setClearDepth(depth));
    }

    public static void setClearStencil(int stencil) {
        ifLoaded(() -> RendererProxy.setClearStencil(stencil));
    }

    public static void clear(int glMask) {
        if (!ShaderMetalClient.isLibraryLoaded()) {
            return;
        }
        if ((glMask & 0x4000) != 0) { // GL_COLOR_BUFFER_BIT
            RendererProxy.vkCmdClearEntireColorAttachment();
        }
        int aspectMask = 0;
        if ((glMask & 0x0100) != 0) { // GL_DEPTH_BUFFER_BIT
            aspectMask |= 0x2;
        }
        if ((glMask & 0x0400) != 0) { // GL_STENCIL_BUFFER_BIT
            aspectMask |= 0x4;
        }
        if (aspectMask != 0) {
            RendererProxy.vkCmdClearEntireDepthStencilAttachment(aspectMask);
        }
    }

    private static int blendFactor(int factor) {
        return switch (factor) {
            case 0 -> 0; // GL_ZERO
            case 1 -> 1; // GL_ONE
            case 0x0300 -> 2; // GL_SRC_COLOR
            case 0x0301 -> 3; // GL_ONE_MINUS_SRC_COLOR
            case 0x0306 -> 4; // GL_DST_COLOR
            case 0x0307 -> 5; // GL_ONE_MINUS_DST_COLOR
            case 0x0302 -> 6; // GL_SRC_ALPHA
            case 0x0303 -> 7; // GL_ONE_MINUS_SRC_ALPHA
            case 0x0304 -> 8; // GL_DST_ALPHA
            case 0x0305 -> 9; // GL_ONE_MINUS_DST_ALPHA
            case 0x8001 -> 10; // GL_CONSTANT_COLOR
            case 0x8002 -> 11; // GL_ONE_MINUS_CONSTANT_COLOR
            case 0x8003 -> 12; // GL_CONSTANT_ALPHA
            case 0x8004 -> 13; // GL_ONE_MINUS_CONSTANT_ALPHA
            case 0x0308 -> 14; // GL_SRC_ALPHA_SATURATE
            case 0x88f9 -> 15; // GL_SRC1_COLOR
            case 0x88fa -> 16; // GL_ONE_MINUS_SRC1_COLOR
            case 0x8589 -> 17; // GL_SRC1_ALPHA
            case 0x88fb -> 18; // GL_ONE_MINUS_SRC1_ALPHA
            default -> throw new IllegalArgumentException(
                "Unsupported OpenGL blend factor 0x" + Integer.toHexString(factor));
        };
    }

    private static int blendOperation(int operation) {
        return switch (operation) {
            case 0x8006 -> 0; // GL_FUNC_ADD
            case 0x800a -> 1; // GL_FUNC_SUBTRACT
            case 0x800b -> 2; // GL_FUNC_REVERSE_SUBTRACT
            case 0x8007 -> 3; // GL_MIN
            case 0x8008 -> 4; // GL_MAX
            default -> throw new IllegalArgumentException(
                "Unsupported OpenGL blend operation 0x" + Integer.toHexString(operation));
        };
    }

    private static int compareOperation(int function) {
        return switch (function) {
            case 0x0200 -> 0; // GL_NEVER
            case 0x0201 -> 1; // GL_LESS
            case 0x0202 -> 2; // GL_EQUAL
            case 0x0203 -> 3; // GL_LEQUAL
            case 0x0204 -> 4; // GL_GREATER
            case 0x0205 -> 5; // GL_NOTEQUAL
            case 0x0206 -> 6; // GL_GEQUAL
            case 0x0207 -> 7; // GL_ALWAYS
            default -> throw new IllegalArgumentException(
                "Unsupported OpenGL compare operation 0x" + Integer.toHexString(function));
        };
    }

    private static int stencilOperation(int operation) {
        return switch (operation) {
            case 0x1e00 -> 0; // GL_KEEP
            case 0 -> 1; // GL_ZERO
            case 0x1e01 -> 2; // GL_REPLACE
            case 0x1e02 -> 3; // GL_INCR
            case 0x1e03 -> 4; // GL_DECR
            case 0x150a -> 5; // GL_INVERT
            case 0x8507 -> 6; // GL_INCR_WRAP
            case 0x8508 -> 7; // GL_DECR_WRAP
            default -> throw new IllegalArgumentException(
                "Unsupported OpenGL stencil operation 0x" + Integer.toHexString(operation));
        };
    }

    private static int logicOperation(int operation) {
        if (operation < 0x1500 || operation > 0x150f) {
            throw new IllegalArgumentException(
                "Unsupported OpenGL logic operation 0x" + Integer.toHexString(operation));
        }
        return operation - 0x1500;
    }

    private static int polygonMode(int mode) {
        return switch (mode) {
            case 0x1b02 -> 0; // GL_FILL
            case 0x1b01 -> 1; // GL_LINE
            case 0x1b00 -> 2; // GL_POINT
            default -> throw new IllegalArgumentException(
                "Unsupported OpenGL polygon mode 0x" + Integer.toHexString(mode));
        };
    }

    private static void ifLoaded(Runnable operation) {
        if (ShaderMetalClient.isLibraryLoaded()) {
            operation.run();
        }
    }
}
