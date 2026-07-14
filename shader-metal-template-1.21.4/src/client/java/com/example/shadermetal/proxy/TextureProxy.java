package com.example.shadermetal.proxy;

public final class TextureProxy {
    private TextureProxy() {
    }

    public static synchronized native int generateTextureId();

    public static synchronized native void prepareImage(int id, int mipLevels, int width,
        int height, int format);

    public static synchronized native void setFilter(int id, int samplingMode, int mipmapMode);

    public static synchronized native void setClamp(int id, int addressMode);

    public static synchronized native void queueUpload(long source, int sourceSizeInBytes,
        int sourceRowPixels, int destinationId, int sourceOffsetX, int sourceOffsetY,
        int destinationOffsetX, int destinationOffsetY, int width, int height, int level);

    public static synchronized native void uploadEmissionTile(int textureId, long tileKey,
        long cells, int cellCount);
}
