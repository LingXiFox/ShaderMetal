package com.example.shadermetal.proxy;

public final class ShaderProxy {
    private ShaderProxy() {
    }

    public static native int registerShader(String key, int vertexFormatType, int drawMode,
        int uniformSize, String vertexSource, String fragmentSource);
}
