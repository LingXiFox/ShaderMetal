package com.example.shadermetal.proxy;

public final class DrawCommandProxy {
    private DrawCommandProxy() {
    }

    public static void draw(int vertexId, int indexId, int shaderId, int indexCount,
        int indexType, long uniformData, int uniformSize, int instanceCount, int firstIndex,
        int firstVertex) {
        draw(vertexId, indexId, shaderId, indexCount, indexType, uniformData, uniformSize,
            instanceCount, firstIndex, firstVertex, true);
    }

    public static native void draw(int vertexId, int indexId, int shaderId, int indexCount,
        int indexType, long uniformData, int uniformSize, int instanceCount, int firstIndex,
        int firstVertex, boolean transientBuffers);
}
