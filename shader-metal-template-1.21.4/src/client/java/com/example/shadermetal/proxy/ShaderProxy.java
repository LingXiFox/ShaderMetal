package com.example.shadermetal.proxy;

public final class ShaderProxy {
    private ShaderProxy() {
    }

    public static native int registerShader(String key, int vertexFormatType,
        String vertexSource, String fragmentSource, long uniformData);
}
