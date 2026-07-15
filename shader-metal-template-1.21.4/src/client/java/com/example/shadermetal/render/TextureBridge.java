package com.example.shadermetal.render;

import com.example.shadermetal.ShaderMetalClient;
import com.example.shadermetal.proxy.TextureProxy;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import net.minecraft.client.texture.NativeImage;
import org.lwjgl.system.MemoryUtil;

public final class TextureBridge {
    private static final int VK_FORMAT_R8_UNORM = 9;
    private static final int VK_FORMAT_R8G8_UNORM = 16;
    private static final int VK_FORMAT_R8G8B8_UNORM = 23;
    private static final int VK_FORMAT_R8G8B8A8_UNORM = 37;

    private static final ConcurrentMap<Integer, TextureRecord> TEXTURES =
        new ConcurrentHashMap<>();
    private static volatile boolean rendererReady;

    private TextureBridge() {
    }

    public static void registerGeneratedTexture(int glId) {
        if (glId > 0) {
            TEXTURES.computeIfAbsent(glId, ignored -> new TextureRecord());
        }
    }

    public static void releaseTexture(int glId) {
        TEXTURES.remove(glId);
    }

    public static void prepareImage(int glId, NativeImage.InternalFormat format,
        int maxLevel, int width, int height) {
        if (glId <= 0) {
            return;
        }
        TextureRecord record = TEXTURES.computeIfAbsent(glId,
            ignored -> new TextureRecord());
        synchronized (record) {
            record.preparation = new Preparation(maxLevel + 1, width, height,
                vkFormat(format));
            record.prepared = false;
            applyIfReady(record);
        }
    }

    public static void setFilter(int glId, boolean bilinear, boolean mipmap) {
        if (glId <= 0) {
            return;
        }
        TextureRecord record = TEXTURES.computeIfAbsent(glId,
            ignored -> new TextureRecord());
        synchronized (record) {
            record.samplingMode = bilinear ? 1 : 0;
            record.mipmapMode = mipmap ? 1 : 0;
            record.filterDirty = true;
            applyIfReady(record);
        }
    }

    public static void setClamp(int glId, boolean clamp) {
        if (glId <= 0) {
            return;
        }
        TextureRecord record = TEXTURES.computeIfAbsent(glId,
            ignored -> new TextureRecord());
        synchronized (record) {
            record.addressMode = clamp ? 2 : 0;
            record.clampDirty = true;
            applyIfReady(record);
        }
    }

    public static void queueUpload(int glId, long source, int sourceSizeInBytes,
        int sourceRowPixels, int sourceOffsetX, int sourceOffsetY,
        int destinationOffsetX, int destinationOffsetY, int width, int height, int level) {
        if (glId <= 0 || source == 0) {
            return;
        }
        TextureRecord record = TEXTURES.computeIfAbsent(glId,
            ignored -> new TextureRecord());
        synchronized (record) {
            Upload upload = new Upload(null, sourceSizeInBytes, sourceRowPixels,
                sourceOffsetX, sourceOffsetY, destinationOffsetX, destinationOffsetY,
                width, height, level);
            if (rendererReady) {
                applyPreparation(record);
                queueNativeUpload(record, upload, source);
            } else {
                ByteBuffer view = MemoryUtil.memByteBuffer(source, sourceSizeInBytes);
                byte[] copy = new byte[sourceSizeInBytes];
                view.get(copy);
                record.pendingUploads.add(upload.withBytes(copy));
            }
        }
    }

    public static void flushPending() {
        if (!ShaderMetalClient.isLibraryLoaded()) {
            throw new IllegalStateException("ShaderMetal native library is not loaded");
        }
        rendererReady = true;
        for (TextureRecord record : TEXTURES.values()) {
            synchronized (record) {
                applyRecord(record);
            }
        }
    }

    public static int nativeTextureId(int glId) {
        if (glId <= 0) {
            return 0;
        }
        TextureRecord record = TEXTURES.computeIfAbsent(glId,
            ignored -> new TextureRecord());
        synchronized (record) {
            int nativeId = ensureNativeId(record);
            if (nativeId >= GlslTranslator.BINDLESS_TEXTURE_COUNT) {
                throw new IllegalStateException("Bindless texture table exhausted at native ID "
                    + nativeId);
            }
            return nativeId;
        }
    }

    private static void applyIfReady(TextureRecord record) {
        if (rendererReady) {
            applyRecord(record);
        }
    }

    private static void applyRecord(TextureRecord record) {
        applyPreparation(record);
        int nativeId = ensureNativeId(record);
        if (record.filterDirty) {
            TextureProxy.setFilter(nativeId, record.samplingMode, record.mipmapMode);
            record.filterDirty = false;
        }
        if (record.clampDirty) {
            TextureProxy.setClamp(nativeId, record.addressMode);
            record.clampDirty = false;
        }
        while (!record.pendingUploads.isEmpty()) {
            Upload upload = record.pendingUploads.get(0);
            if (upload.bytes() == null) {
                throw new IllegalStateException("Deferred texture upload has no retained bytes");
            }
            ByteBuffer copy = MemoryUtil.memAlloc(upload.bytes().length);
            try {
                copy.put(upload.bytes()).flip();
                queueNativeUpload(record, upload, MemoryUtil.memAddress(copy));
                record.pendingUploads.remove(0);
            } finally {
                MemoryUtil.memFree(copy);
            }
        }
    }

    private static void applyPreparation(TextureRecord record) {
        if (record.prepared) {
            return;
        }
        Preparation preparation = record.preparation;
        if (preparation == null) {
            if (!record.pendingUploads.isEmpty()) {
                throw new IllegalStateException(
                    "Texture upload reached Metal before TextureUtil.prepareImage");
            }
            return;
        }
        TextureProxy.prepareImage(ensureNativeId(record), preparation.mipLevels(),
            preparation.width(), preparation.height(), preparation.vkFormat());
        record.prepared = true;
    }

    private static void queueNativeUpload(TextureRecord record, Upload upload, long source) {
        if (!record.prepared) {
            throw new IllegalStateException("Native texture is not prepared for upload");
        }
        TextureProxy.queueUpload(source, upload.sourceSizeInBytes(),
            upload.sourceRowPixels(), ensureNativeId(record), upload.sourceOffsetX(),
            upload.sourceOffsetY(), upload.destinationOffsetX(), upload.destinationOffsetY(),
            upload.width(), upload.height(), upload.level());
    }

    private static int ensureNativeId(TextureRecord record) {
        if (record.nativeId > 0) {
            return record.nativeId;
        }
        if (!ShaderMetalClient.isLibraryLoaded()) {
            throw new IllegalStateException(
                "Texture was requested before the ShaderMetal native library loaded");
        }
        int nativeId = TextureProxy.generateTextureId();
        if (nativeId <= 0) {
            throw new IllegalStateException("Unable to allocate native texture");
        }
        record.nativeId = nativeId;
        return nativeId;
    }

    private static int vkFormat(NativeImage.InternalFormat format) {
        if (format == NativeImage.InternalFormat.RGBA) return VK_FORMAT_R8G8B8A8_UNORM;
        if (format == NativeImage.InternalFormat.RGB) return VK_FORMAT_R8G8B8_UNORM;
        if (format == NativeImage.InternalFormat.RG) return VK_FORMAT_R8G8_UNORM;
        if (format == NativeImage.InternalFormat.RED) return VK_FORMAT_R8_UNORM;
        throw new IllegalArgumentException("Unsupported NativeImage format " + format);
    }

    private static final class TextureRecord {
        private int nativeId;
        private Preparation preparation;
        private boolean prepared;
        private int samplingMode;
        private int mipmapMode;
        private boolean filterDirty;
        private int addressMode;
        private boolean clampDirty;
        private final List<Upload> pendingUploads = new ArrayList<>();
    }

    private record Preparation(int mipLevels, int width, int height, int vkFormat) {
    }

    private record Upload(byte[] bytes, int sourceSizeInBytes, int sourceRowPixels,
                          int sourceOffsetX, int sourceOffsetY, int destinationOffsetX,
                          int destinationOffsetY, int width, int height, int level) {
        private Upload withBytes(byte[] retainedBytes) {
            return new Upload(retainedBytes, sourceSizeInBytes, sourceRowPixels,
                sourceOffsetX, sourceOffsetY, destinationOffsetX, destinationOffsetY,
                width, height, level);
        }
    }
}
