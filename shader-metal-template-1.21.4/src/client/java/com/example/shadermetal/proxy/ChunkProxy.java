package com.example.shadermetal.proxy;

public final class ChunkProxy {
    private ChunkProxy() {
    }

    public static native void initNative(int chunkCount, int sizeX, int sizeY, int sizeZ,
        int bottomSectionCoordinate);

    public static native void updateSectionPosNative(int sectionX, int sectionY, int sectionZ);

    public static native void build(int originX, int originY, int originZ, long index,
        int geometryCount, long geometryTypes, long geometryGroupNames, long geometryTextures,
        long vertexFormats, long vertexCounts, long vertices, boolean important);

    public static native boolean isChunkReady(long index);

    public static native void relocateSingle(long index, int originX, int originY, int originZ);

    public static native void invalidateSingle(long index);
}
