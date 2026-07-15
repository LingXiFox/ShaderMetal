package com.example.shadermetal.proxy;

public final class BufferProxy {
    private BufferProxy() {
    }

    public static native int allocateBuffer();

    public static native void releaseBuffer(int id);

    public static native void initializeBuffer(int id, int size, int usageFlags);

    public static native void queueUpload(long source, int destinationId);

    public static native void performQueuedUpload();

    public static native void buildIndexBuffer(int id, int indexType, int drawMode,
        int vertexCount, int expectedIndexCount);

    public static native void updateMapping(long source);
}
