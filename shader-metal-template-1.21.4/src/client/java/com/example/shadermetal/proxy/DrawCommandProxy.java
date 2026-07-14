package com.example.shadermetal.proxy;

public final class DrawCommandProxy {
    private DrawCommandProxy() {
    }

    public static native void draw(int vertexId, int indexId, int shaderId, int indexCount,
        int instanceCount, int firstIndex, int firstVertex);
}
