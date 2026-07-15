package com.example.shadermetal.render;

import com.example.shadermetal.ShaderMetalClient;
import com.example.shadermetal.proxy.BufferProxy;
import com.example.shadermetal.proxy.DrawCommandProxy;
import com.example.shadermetal.proxy.ShaderProxy;
import com.mojang.blaze3d.systems.RenderSystem;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import net.minecraft.client.MinecraftClient;
import net.minecraft.client.gl.CompiledShader;
import net.minecraft.client.gl.GlUniform;
import net.minecraft.client.gl.ShaderProgram;
import net.minecraft.client.gl.ShaderProgramDefinition;
import net.minecraft.client.gl.VertexBuffer;
import net.minecraft.client.render.BuiltBuffer;
import net.minecraft.client.render.VertexFormat;
import net.minecraft.client.render.VertexFormats;
import net.minecraft.client.util.BufferAllocator;
import net.minecraft.util.Identifier;
import org.lwjgl.system.MemoryUtil;

public final class CoreShaderBridge {
    private static final int VERTEX_BUFFER_USAGE = 0x80;
    private static final int INDEX_BUFFER_USAGE = 0x40;
    private static final Pattern SAMPLER_SLOT = Pattern.compile(".*?(\\d+)$");

    private static final Map<CompiledShader, CapturedShader> COMPILED_SHADERS =
        new WeakHashMap<>();
    private static final Map<ShaderProgram, ProgramInfo> PROGRAMS = new WeakHashMap<>();
    private static final Map<VertexBuffer, PersistentVertexBuffer> PERSISTENT_VERTEX_BUFFERS =
        new IdentityHashMap<>();
    private static final AtomicBoolean FIRST_DRAW_LOGGED = new AtomicBoolean();
    private static final AtomicBoolean FIRST_PERSISTENT_DRAW_LOGGED = new AtomicBoolean();
    private static volatile ShaderProgram boundProgram;

    private CoreShaderBridge() {
    }

    public static void captureCompiledShader(CompiledShader shader, Identifier id,
        CompiledShader.Type type, String source) {
        synchronized (COMPILED_SHADERS) {
            COMPILED_SHADERS.put(shader, new CapturedShader(id.toString(), type, source));
        }
    }

    public static void captureProgram(ShaderProgram program, CompiledShader vertexShader,
        CompiledShader fragmentShader, VertexFormat format) {
        CapturedShader vertex;
        CapturedShader fragment;
        synchronized (COMPILED_SHADERS) {
            vertex = COMPILED_SHADERS.get(vertexShader);
            fragment = COMPILED_SHADERS.get(fragmentShader);
        }
        if (vertex == null || fragment == null) {
            throw new IllegalStateException("ShaderMetal missed a compiled core shader source");
        }
        if (vertex.type() != CompiledShader.Type.VERTEX
            || fragment.type() != CompiledShader.Type.FRAGMENT) {
            throw new IllegalArgumentException("ShaderProgram stages were captured out of order");
        }
        synchronized (PROGRAMS) {
            PROGRAMS.put(program, new ProgramInfo(vertex, fragment, format));
        }
    }

    public static void captureDefinitions(ShaderProgram program,
        List<ShaderProgramDefinition.Uniform> uniforms,
        List<ShaderProgramDefinition.Sampler> samplers) {
        ProgramInfo info = requireProgramInfo(program);
        synchronized (info) {
            info.uniformDefinitions = List.copyOf(uniforms);
            info.samplerDefinitions = List.copyOf(samplers);
            info.layout = null;
            info.shaderIds.clear();
        }
    }

    public static void captureSamplerTexture(ShaderProgram program, String name, int textureId) {
        ProgramInfo info = requireProgramInfo(program);
        synchronized (info) {
            info.samplerTextures.put(name, textureId);
        }
    }

    public static void captureBoundProgram(ShaderProgram program) {
        boundProgram = program;
    }

    public static void clearBoundProgram() {
        boundProgram = null;
    }

    public static void captureVertexBufferUpload(VertexBuffer vertexBuffer,
        BuiltBuffer builtBuffer) {
        if (vertexBuffer.isClosed()) {
            return;
        }
        try {
            RenderSystem.assertOnRenderThread();
            PersistentVertexBuffer replacement = retainPersistentVertexBuffer(builtBuffer);
            PersistentVertexBuffer previous;
            synchronized (PERSISTENT_VERTEX_BUFFERS) {
                previous = PERSISTENT_VERTEX_BUFFERS.put(vertexBuffer, replacement);
            }
            releasePersistentBuffers(previous);
        } catch (RuntimeException | Error exception) {
            try {
                builtBuffer.close();
            } catch (RuntimeException | Error closeException) {
                exception.addSuppressed(closeException);
            }
            throw exception;
        }
    }

    public static void captureVertexBufferIndexUpload(VertexBuffer vertexBuffer,
        BufferAllocator.CloseableBuffer indexBuffer) {
        if (vertexBuffer.isClosed()) {
            return;
        }
        try {
            RenderSystem.assertOnRenderThread();
            PersistentVertexBuffer persistent;
            synchronized (PERSISTENT_VERTEX_BUFFERS) {
                persistent = PERSISTENT_VERTEX_BUFFERS.get(vertexBuffer);
            }
            if (persistent == null) {
                throw new IllegalStateException(
                    "VertexBuffer index upload has no retained vertex upload");
            }

            int oldIndexId;
            synchronized (persistent) {
                int expectedSize = Math.multiplyExact(persistent.indexCount,
                    bytesPerIndex(persistent.indexType));
                persistent.indexBytes = copyBytes(indexBuffer.getBuffer(), expectedSize,
                    "VertexBuffer reordered index");
                oldIndexId = persistent.indexId;
                persistent.indexId = 0;
            }
            releaseNativeBuffer(oldIndexId);
        } catch (RuntimeException | Error exception) {
            try {
                indexBuffer.close();
            } catch (RuntimeException | Error closeException) {
                exception.addSuppressed(closeException);
            }
            throw exception;
        }
    }

    public static void drawVertexBuffer(VertexBuffer vertexBuffer) {
        RenderSystem.assertOnRenderThread();
        PersistentVertexBuffer persistent;
        synchronized (PERSISTENT_VERTEX_BUFFERS) {
            persistent = PERSISTENT_VERTEX_BUFFERS.get(vertexBuffer);
        }
        if (persistent == null) {
            throw new IllegalStateException("VertexBuffer draw has no retained upload");
        }

        synchronized (persistent) {
            if (persistent.indexCount == 0) {
                return;
            }
        }

        ShaderProgram program = boundProgram;
        if (program == null) {
            throw new IllegalStateException("VertexBuffer draw has no bound ShaderProgram");
        }

        synchronized (persistent) {
            if (FIRST_PERSISTENT_DRAW_LOGGED.compareAndSet(false, true)) {
                ShaderMetalClient.LOGGER.info(
                    "Intercepted first persistent draw: vertices={}, indices={}, mode={}, format={}",
                    persistent.vertexCount, persistent.indexCount, persistent.drawMode,
                    persistent.vertexFormat);
            }

            ProgramInfo info = requireProgramInfo(program);
            if (!info.format.equals(persistent.vertexFormat)) {
                throw new IllegalStateException("VertexBuffer format "
                    + persistent.vertexFormat.getAttributeNames()
                    + " does not match bound shader format "
                    + info.format.getAttributeNames());
            }

            RegisteredProgram registered = requireRegisteredProgram(program, info,
                persistent.drawMode);
            MaterializedBuffers materialized = materializePersistentBuffers(persistent);
            if (materialized.vertexId() > 0 || materialized.indexId() > 0) {
                try {
                    BufferProxy.performQueuedUpload();
                } catch (RuntimeException | Error exception) {
                    rollbackMaterializedBuffers(persistent, materialized);
                    throw exception;
                }
            }
            if (materialized.vertexId() > 0) {
                persistent.vertexBytes = null;
            }
            if (materialized.indexId() > 0) {
                persistent.indexBytes = null;
            }

            ByteBuffer uniforms = MemoryUtil.memAlloc(registered.layout().size())
                .order(ByteOrder.nativeOrder());
            try {
                MemoryUtil.memSet(MemoryUtil.memAddress(uniforms), 0,
                    registered.layout().size());
                // VertexBuffer's outer draw overload has already initialized explicit matrices.
                packUniforms(program, info, registered.layout(), uniforms);
                DrawCommandProxy.draw(persistent.vertexId, persistent.indexId,
                    registered.shaderId(), persistent.indexCount, persistent.indexType,
                    MemoryUtil.memAddress(uniforms), registered.layout().size(), 1, 0, 0,
                    false);
            } finally {
                MemoryUtil.memFree(uniforms);
            }
        }
    }

    public static void releaseVertexBuffer(VertexBuffer vertexBuffer) {
        PersistentVertexBuffer persistent;
        synchronized (PERSISTENT_VERTEX_BUFFERS) {
            persistent = PERSISTENT_VERTEX_BUFFERS.remove(vertexBuffer);
        }
        try {
            releasePersistentBuffers(persistent);
        } catch (RuntimeException | Error exception) {
            // A native cleanup failure must not prevent vanilla VertexBuffer.close().
            ShaderMetalClient.LOGGER.warn("Unable to release retained VertexBuffer resources",
                exception);
        }
    }

    public static void close() {
        List<PersistentVertexBuffer> persistentBuffers;
        synchronized (PERSISTENT_VERTEX_BUFFERS) {
            persistentBuffers = new ArrayList<>(PERSISTENT_VERTEX_BUFFERS.values());
            PERSISTENT_VERTEX_BUFFERS.clear();
        }
        for (PersistentVertexBuffer persistent : persistentBuffers) {
            releasePersistentBuffers(persistent);
        }
        synchronized (PROGRAMS) {
            for (ProgramInfo info : PROGRAMS.values()) {
                synchronized (info) {
                    info.shaderIds.clear();
                }
            }
        }
        boundProgram = null;
    }

    public static void drawWithGlobalProgram(BuiltBuffer builtBuffer) {
        draw(builtBuffer, RenderSystem.getShader());
    }

    public static void drawBoundProgram(BuiltBuffer builtBuffer) {
        draw(builtBuffer, boundProgram);
    }

    private static void draw(BuiltBuffer builtBuffer, ShaderProgram program) {
        RenderSystem.assertOnRenderThread();
        try {
            drawAndRetainNativeResources(builtBuffer, program);
        } finally {
            builtBuffer.close();
        }
    }

    private static void drawAndRetainNativeResources(BuiltBuffer builtBuffer,
        ShaderProgram program) {
        BuiltBuffer.DrawParameters parameters = builtBuffer.getDrawParameters();
        if (FIRST_DRAW_LOGGED.compareAndSet(false, true)) {
            ShaderMetalClient.LOGGER.info(
                "Intercepted first core draw: vertices={}, indices={}, mode={}, format={}, shader={}",
                parameters.vertexCount(), parameters.indexCount(), parameters.mode(),
                parameters.format(), program != null);
        }
        if (parameters.vertexCount() == 0 || parameters.indexCount() == 0) {
            return;
        }

        if (program == null) {
            throw new IllegalStateException("BuiltBuffer draw has no active ShaderProgram");
        }
        ProgramInfo info = requireProgramInfo(program);
        program.initializeUniforms(parameters.mode(), RenderSystem.getModelViewMatrix(),
            RenderSystem.getProjectionMatrix(), MinecraftClient.getInstance().getWindow());

        RegisteredProgram registered = requireRegisteredProgram(program, info,
            parameters.mode());

        int vertexId = 0;
        int indexId = 0;
        boolean enqueued = false;
        try {
            vertexId = uploadVertexBuffer(builtBuffer, parameters);
            UploadedIndexBuffer indexBuffer = uploadIndexBuffer(builtBuffer, parameters);
            indexId = indexBuffer.id();
            ByteBuffer uniforms = MemoryUtil.memAlloc(registered.layout().size())
                .order(ByteOrder.nativeOrder());
            try {
                MemoryUtil.memSet(MemoryUtil.memAddress(uniforms), 0,
                    registered.layout().size());
                packUniforms(program, info, registered.layout(), uniforms);
                DrawCommandProxy.draw(vertexId, indexId, registered.shaderId(),
                    indexBuffer.indexCount(), indexType(parameters.indexType()),
                    MemoryUtil.memAddress(uniforms), registered.layout().size(), 1, 0, 0);
                enqueued = true;
            } finally {
                MemoryUtil.memFree(uniforms);
            }
        } catch (RuntimeException | Error exception) {
            if (!enqueued) {
                try {
                    releaseNativeBuffers(vertexId, indexId);
                } catch (RuntimeException | Error cleanupException) {
                    exception.addSuppressed(cleanupException);
                }
            }
            throw exception;
        }
    }

    private static RegisteredProgram requireRegisteredProgram(ShaderProgram program,
        ProgramInfo info, VertexFormat.DrawMode drawMode) {
        synchronized (info) {
            UniformLayout layout = info.layout;
            if (layout == null) {
                layout = createLayout(info.uniformDefinitions, info.samplerDefinitions);
                info.layout = layout;
            }
            Integer shaderId = info.shaderIds.get(drawMode);
            if (shaderId == null) {
                shaderId = registerShader(program, info, layout, nativeDrawMode(drawMode));
                info.shaderIds.put(drawMode, shaderId);
            }
            return new RegisteredProgram(layout, shaderId);
        }
    }

    private static PersistentVertexBuffer retainPersistentVertexBuffer(
        BuiltBuffer builtBuffer) {
        BuiltBuffer.DrawParameters parameters = builtBuffer.getDrawParameters();
        int vertexSize = Math.multiplyExact(parameters.vertexCount(),
            parameters.format().getVertexSizeByte());
        byte[] vertexBytes = copyBytes(builtBuffer.getBuffer(), vertexSize,
            "VertexBuffer vertex");

        int nativeIndexType = indexType(parameters.indexType());
        int nativeIndexCount = parameters.mode() == VertexFormat.DrawMode.TRIANGLE_FAN
            ? Math.multiplyExact(Math.max(0, parameters.vertexCount() - 2), 3)
            : parameters.indexCount();
        int indexSize = Math.multiplyExact(nativeIndexCount,
            bytesPerIndex(nativeIndexType));
        byte[] indexBytes = null;
        ByteBuffer sorted = builtBuffer.getSortedBuffer();
        if (sorted != null) {
            indexBytes = copyBytes(sorted, indexSize, "VertexBuffer sorted index");
        } else if (parameters.mode() != VertexFormat.DrawMode.QUADS) {
            indexBytes = new byte[indexSize];
            ByteBuffer generated = ByteBuffer.wrap(indexBytes).order(ByteOrder.nativeOrder());
            writeGeneratedIndices(generated, nativeIndexType, parameters.mode(),
                parameters.vertexCount(), nativeIndexCount);
        }

        return new PersistentVertexBuffer(parameters.vertexCount(), nativeIndexCount,
            nativeIndexType, parameters.mode(), parameters.format(), vertexBytes, indexBytes);
    }

    private static byte[] copyBytes(ByteBuffer source, int expectedSize, String label) {
        ByteBuffer view = source.duplicate();
        if (view.remaining() != expectedSize) {
            throw new IllegalArgumentException(label + " byte count is " + view.remaining()
                + ", expected " + expectedSize);
        }
        byte[] copy = new byte[expectedSize];
        view.get(copy);
        return copy;
    }

    private static int bytesPerIndex(int indexType) {
        return indexType == 0 ? Short.BYTES : Integer.BYTES;
    }

    private static MaterializedBuffers materializePersistentBuffers(
        PersistentVertexBuffer persistent) {
        if (persistent.vertexId > 0 && persistent.indexId > 0) {
            return new MaterializedBuffers(0, 0);
        }
        if (persistent.indexCount == 0) {
            throw new IllegalStateException("Cannot materialize an empty persistent VertexBuffer");
        }

        int newVertexId = 0;
        int newIndexId = 0;
        try {
            if (persistent.vertexId == 0) {
                byte[] vertexBytes = persistent.vertexBytes;
                if (vertexBytes == null || vertexBytes.length == 0) {
                    throw new IllegalStateException(
                        "Persistent VertexBuffer has no retained vertex bytes");
                }
                newVertexId = allocateNativeBuffer(vertexBytes.length,
                    VERTEX_BUFFER_USAGE, "persistent vertex");
                queueNativeUpload(newVertexId, vertexBytes);
            }

            if (persistent.indexId == 0) {
                int indexSize = Math.multiplyExact(persistent.indexCount,
                    bytesPerIndex(persistent.indexType));
                newIndexId = allocateNativeBuffer(indexSize, INDEX_BUFFER_USAGE,
                    "persistent index");
                if (persistent.indexBytes != null) {
                    queueNativeUpload(newIndexId, persistent.indexBytes);
                } else if (persistent.drawMode == VertexFormat.DrawMode.QUADS) {
                    BufferProxy.buildIndexBuffer(newIndexId, persistent.indexType,
                        drawMode(persistent.drawMode), persistent.vertexCount,
                        persistent.indexCount);
                } else {
                    throw new IllegalStateException(
                        "Persistent VertexBuffer has no retained index bytes");
                }
            }

            if (newVertexId > 0) {
                persistent.vertexId = newVertexId;
            }
            if (newIndexId > 0) {
                persistent.indexId = newIndexId;
            }
            return new MaterializedBuffers(newVertexId, newIndexId);
        } catch (RuntimeException | Error exception) {
            releaseNativeBuffer(newVertexId);
            releaseNativeBuffer(newIndexId);
            throw exception;
        }
    }

    private static void rollbackMaterializedBuffers(PersistentVertexBuffer persistent,
        MaterializedBuffers materialized) {
        if (materialized.vertexId() > 0) {
            persistent.vertexId = 0;
            releaseNativeBuffer(materialized.vertexId());
        }
        if (materialized.indexId() > 0) {
            persistent.indexId = 0;
            releaseNativeBuffer(materialized.indexId());
        }
    }

    private static int allocateNativeBuffer(int size, int usage, String label) {
        int id = BufferProxy.allocateBuffer();
        if (id <= 0) {
            throw new IllegalStateException("Unable to allocate native " + label + " buffer");
        }
        try {
            BufferProxy.initializeBuffer(id, size, usage);
            return id;
        } catch (RuntimeException | Error exception) {
            releaseNativeBuffer(id);
            throw exception;
        }
    }

    private static void queueNativeUpload(int id, byte[] bytes) {
        ByteBuffer copy = MemoryUtil.memAlloc(bytes.length).order(ByteOrder.nativeOrder());
        try {
            copy.put(bytes).flip();
            BufferProxy.queueUpload(MemoryUtil.memAddress(copy), id);
        } finally {
            MemoryUtil.memFree(copy);
        }
    }

    private static void releasePersistentBuffers(PersistentVertexBuffer persistent) {
        if (persistent == null) {
            return;
        }
        int vertexId;
        int indexId;
        synchronized (persistent) {
            vertexId = persistent.vertexId;
            indexId = persistent.indexId;
            persistent.vertexId = 0;
            persistent.indexId = 0;
        }
        releaseNativeBuffers(vertexId, indexId);
    }

    private static void releaseNativeBuffers(int vertexId, int indexId) {
        try {
            releaseNativeBuffer(vertexId);
        } catch (RuntimeException | Error exception) {
            try {
                if (indexId != vertexId) {
                    releaseNativeBuffer(indexId);
                }
            } catch (RuntimeException | Error indexException) {
                exception.addSuppressed(indexException);
            }
            throw exception;
        }
        if (indexId != vertexId) {
            releaseNativeBuffer(indexId);
        }
    }

    private static void releaseNativeBuffer(int id) {
        if (id > 0) {
            BufferProxy.releaseBuffer(id);
        }
    }

    private static int registerShader(ShaderProgram program, ProgramInfo info,
        UniformLayout layout, int nativeDrawMode) {
        List<GlslTranslator.UniformDeclaration> declarations = new ArrayList<>();
        for (UniformField field : layout.fields()) {
            declarations.add(new GlslTranslator.UniformDeclaration(
                field.name(), field.glslType(), field.kind() == UniformKind.SAMPLER));
        }
        GlslTranslator.TranslatedProgram translated = GlslTranslator.translate(
            info.vertex.source(), info.fragment.source(), info.format, declarations);
        String key = info.vertex.id() + "+" + info.fragment.id() + "/"
            + Integer.toUnsignedString(System.identityHashCode(program), 16) + "/"
            + nativeDrawMode;
        int shaderId = ShaderProxy.registerShader(key, vertexFormatType(info.format),
            nativeDrawMode, layout.size(), translated.vertexSource(),
            translated.fragmentSource());
        if (shaderId < 0) {
            throw new IllegalStateException("Native shader registration failed for " + key);
        }
        return shaderId;
    }

    private static int uploadVertexBuffer(BuiltBuffer builtBuffer,
        BuiltBuffer.DrawParameters parameters) {
        int size = Math.multiplyExact(parameters.vertexCount(),
            parameters.format().getVertexSizeByte());
        ByteBuffer source = builtBuffer.getBuffer().duplicate();
        if (!source.isDirect() || source.remaining() != size) {
            throw new IllegalArgumentException("BuiltBuffer vertex byte count is "
                + source.remaining() + ", expected " + size);
        }
        int id = allocateNativeBuffer(size, VERTEX_BUFFER_USAGE, "vertex");
        try {
            BufferProxy.queueUpload(MemoryUtil.memAddress(source), id);
            return id;
        } catch (RuntimeException | Error exception) {
            try {
                releaseNativeBuffer(id);
            } catch (RuntimeException | Error cleanupException) {
                exception.addSuppressed(cleanupException);
            }
            throw exception;
        }
    }

    private static UploadedIndexBuffer uploadIndexBuffer(BuiltBuffer builtBuffer,
        BuiltBuffer.DrawParameters parameters) {
        int indexType = indexType(parameters.indexType());
        int bytesPerIndex = indexType == 0 ? Short.BYTES : Integer.BYTES;
        int indexCount = parameters.mode() == VertexFormat.DrawMode.TRIANGLE_FAN
            ? Math.multiplyExact(Math.max(0, parameters.vertexCount() - 2), 3)
            : parameters.indexCount();
        int size = Math.multiplyExact(indexCount, bytesPerIndex);
        if (size == 0) {
            throw new IllegalArgumentException("Draw produced an empty native index buffer");
        }

        int id = allocateNativeBuffer(size, INDEX_BUFFER_USAGE, "index");
        try {
            ByteBuffer sorted = builtBuffer.getSortedBuffer();
            if (sorted != null) {
                ByteBuffer source = sorted.duplicate();
                if (!source.isDirect() || source.remaining() != size) {
                    throw new IllegalArgumentException("BuiltBuffer index byte count is "
                        + source.remaining() + ", expected " + size);
                }
                BufferProxy.queueUpload(MemoryUtil.memAddress(source), id);
            } else if (parameters.mode() == VertexFormat.DrawMode.QUADS) {
                BufferProxy.buildIndexBuffer(id, indexType, drawMode(parameters.mode()),
                    parameters.vertexCount(), indexCount);
            } else {
                ByteBuffer generated = MemoryUtil.memAlloc(size).order(ByteOrder.nativeOrder());
                try {
                    writeGeneratedIndices(generated, indexType, parameters.mode(),
                        parameters.vertexCount(), indexCount);
                    BufferProxy.queueUpload(MemoryUtil.memAddress(generated), id);
                } finally {
                    MemoryUtil.memFree(generated);
                }
            }
            return new UploadedIndexBuffer(id, indexCount);
        } catch (RuntimeException | Error exception) {
            try {
                releaseNativeBuffer(id);
            } catch (RuntimeException | Error cleanupException) {
                exception.addSuppressed(cleanupException);
            }
            throw exception;
        }
    }

    private static void writeGeneratedIndices(ByteBuffer target, int indexType,
        VertexFormat.DrawMode mode, int vertexCount, int indexCount) {
        if (mode == VertexFormat.DrawMode.TRIANGLE_FAN) {
            int expectedCount = Math.multiplyExact(Math.max(0, vertexCount - 2), 3);
            if (indexCount != expectedCount) {
                throw new IllegalArgumentException("Triangle fan index count is " + indexCount
                    + ", expected " + expectedCount);
            }
            writeTriangleFanIndices(target, indexType, vertexCount);
            return;
        }
        if (mode == VertexFormat.DrawMode.LINES) {
            if (vertexCount % 4 != 0) {
                throw new IllegalArgumentException(
                    "Expanded line vertex count must be divisible by four");
            }
            int expectedCount = Math.multiplyExact(vertexCount / 4, 6);
            if (indexCount != expectedCount) {
                throw new IllegalArgumentException("Expanded line index count is " + indexCount
                    + ", expected " + expectedCount);
            }
            for (int base = 0, output = 0; base < vertexCount; base += 4, output += 6) {
                putIndex(target, indexType, output, base);
                putIndex(target, indexType, output + 1, base + 1);
                putIndex(target, indexType, output + 2, base + 2);
                putIndex(target, indexType, output + 3, base + 3);
                putIndex(target, indexType, output + 4, base + 2);
                putIndex(target, indexType, output + 5, base + 1);
            }
            return;
        }
        if (indexCount > vertexCount) {
            throw new IllegalArgumentException(
                "Sequential index count exceeds the vertex count");
        }
        for (int index = 0; index < indexCount; index++) {
            putIndex(target, indexType, index, index);
        }
    }

    private static void writeTriangleFanIndices(ByteBuffer target, int indexType,
        int vertexCount) {
        int output = 0;
        for (int vertex = 1; vertex + 1 < vertexCount; vertex++) {
            putIndex(target, indexType, output++, 0);
            putIndex(target, indexType, output++, vertex);
            putIndex(target, indexType, output++, vertex + 1);
        }
    }

    private static void putIndex(ByteBuffer target, int indexType, int output, int value) {
        if (indexType == 0) {
            if (value > 0xffff) {
                throw new IllegalArgumentException("Vertex index exceeds uint16 range");
            }
            target.putShort(output * Short.BYTES, (short) value);
        } else {
            target.putInt(output * Integer.BYTES, value);
        }
    }

    private static UniformLayout createLayout(
        List<ShaderProgramDefinition.Uniform> uniformDefinitions,
        List<ShaderProgramDefinition.Sampler> samplerDefinitions) {
        List<UniformField> fields = new ArrayList<>();
        Map<String, Boolean> names = new LinkedHashMap<>();
        int offset = 0;
        for (ShaderProgramDefinition.Uniform definition : uniformDefinitions) {
            if (names.put(definition.name(), Boolean.TRUE) != null) {
                throw new IllegalArgumentException(
                    "Duplicate uniform definition " + definition.name());
            }
            FieldShape shape = uniformShape(definition);
            offset = align(offset, shape.alignment());
            fields.add(new UniformField(definition.name(), shape.glslType(),
                shape.kind(), offset, shape.componentCount(), shape.matrixDimension(), -1));
            offset = Math.addExact(offset, shape.size());
        }
        for (int samplerIndex = 0; samplerIndex < samplerDefinitions.size(); samplerIndex++) {
            String name = samplerDefinitions.get(samplerIndex).name();
            if (names.put(name, Boolean.TRUE) != null) {
                throw new IllegalArgumentException("Duplicate sampler definition " + name);
            }
            offset = align(offset, Integer.BYTES);
            fields.add(new UniformField(name, "uint", UniformKind.SAMPLER, offset,
                1, 0, samplerIndex));
            offset = Math.addExact(offset, Integer.BYTES);
        }
        int size = align(Math.max(offset, Integer.BYTES), 16);
        return new UniformLayout(List.copyOf(fields), size);
    }

    private static FieldShape uniformShape(ShaderProgramDefinition.Uniform definition) {
        return switch (definition.type()) {
            case "float" -> vectorShape(false, definition.count());
            case "int" -> vectorShape(true, definition.count());
            case "matrix2x2" -> new FieldShape("mat2", UniformKind.MATRIX, 16, 32, 4, 2);
            case "matrix3x3" -> new FieldShape("mat3", UniformKind.MATRIX, 16, 48, 9, 3);
            case "matrix4x4" -> new FieldShape("mat4", UniformKind.MATRIX, 16, 64, 16, 4);
            default -> throw new IllegalArgumentException(
                "Unsupported core uniform type " + definition.type());
        };
    }

    private static FieldShape vectorShape(boolean integer, int componentCount) {
        if (componentCount < 1 || componentCount > 4) {
            throw new IllegalArgumentException(
                "Unsupported core uniform vector width " + componentCount);
        }
        String glslType;
        if (componentCount == 1) {
            glslType = integer ? "int" : "float";
        } else {
            glslType = (integer ? "ivec" : "vec") + componentCount;
        }
        int alignment = componentCount == 1 ? 4 : componentCount == 2 ? 8 : 16;
        int size = componentCount <= 2 ? componentCount * 4 : 16;
        return new FieldShape(glslType, integer ? UniformKind.INT : UniformKind.FLOAT,
            alignment, size, componentCount, 0);
    }

    private static void packUniforms(ShaderProgram program, ProgramInfo info,
        UniformLayout layout, ByteBuffer target) {
        Map<String, Integer> samplerTextures;
        synchronized (info) {
            samplerTextures = new HashMap<>(info.samplerTextures);
        }
        for (UniformField field : layout.fields()) {
            if (field.kind() == UniformKind.SAMPLER) {
                int textureId = samplerTextures.getOrDefault(field.name(),
                    RenderSystem.getShaderTexture(samplerSlot(field.name(), field.samplerIndex())));
                target.putInt(field.offset(), TextureBridge.nativeTextureId(textureId));
                continue;
            }

            GlUniform uniform = program.getUniform(field.name());
            if (uniform == null) {
                // OpenGL omits uniforms optimized out at link time. The target buffer is
                // already zeroed, so preserve that inert value for Metal's matching field.
                continue;
            }
            switch (field.kind()) {
                case INT -> copyInts(uniform.getIntData(), target, field);
                case FLOAT -> copyFloats(uniform.getFloatData(), target, field);
                case MATRIX -> copyMatrix(uniform.getFloatData(), target, field);
                case SAMPLER -> throw new AssertionError("sampler handled above");
            }
        }
    }

    private static void copyInts(IntBuffer source, ByteBuffer target, UniformField field) {
        if (source == null || source.capacity() < field.componentCount()) {
            throw new IllegalStateException("Uniform " + field.name() + " has no int data");
        }
        for (int index = 0; index < field.componentCount(); index++) {
            target.putInt(field.offset() + index * Integer.BYTES, source.get(index));
        }
    }

    private static void copyFloats(FloatBuffer source, ByteBuffer target, UniformField field) {
        if (source == null || source.capacity() < field.componentCount()) {
            throw new IllegalStateException("Uniform " + field.name() + " has no float data");
        }
        for (int index = 0; index < field.componentCount(); index++) {
            target.putFloat(field.offset() + index * Float.BYTES, source.get(index));
        }
    }

    private static void copyMatrix(FloatBuffer source, ByteBuffer target, UniformField field) {
        int dimension = field.matrixDimension();
        if (source == null || source.capacity() < dimension * dimension) {
            throw new IllegalStateException("Uniform " + field.name() + " has no matrix data");
        }
        for (int column = 0; column < dimension; column++) {
            for (int row = 0; row < dimension; row++) {
                float value = source.get(column * dimension + row);
                target.putFloat(field.offset() + column * 16 + row * Float.BYTES, value);
            }
        }
    }

    private static int samplerSlot(String name, int fallback) {
        Matcher matcher = SAMPLER_SLOT.matcher(name);
        if (matcher.matches()) {
            try {
                return Integer.parseInt(matcher.group(1));
            } catch (NumberFormatException ignored) {
                return fallback;
            }
        }
        return fallback;
    }

    private static ProgramInfo requireProgramInfo(ShaderProgram program) {
        synchronized (PROGRAMS) {
            ProgramInfo info = PROGRAMS.get(program);
            if (info == null) {
                throw new IllegalStateException(
                    "ShaderMetal has no source metadata for the active ShaderProgram");
            }
            return info;
        }
    }

    private static int vertexFormatType(VertexFormat format) {
        if (format == VertexFormats.POSITION_COLOR_TEXTURE_LIGHT_NORMAL) return 0;
        if (format == VertexFormats.POSITION_COLOR_TEXTURE_OVERLAY_LIGHT_NORMAL) return 1;
        if (format == VertexFormats.POSITION_TEXTURE_COLOR_LIGHT) return 2;
        if (format == VertexFormats.POSITION || format == VertexFormats.BLIT_SCREEN) return 3;
        if (format == VertexFormats.POSITION_COLOR) return 4;
        if (format == VertexFormats.LINES) return 5;
        if (format == VertexFormats.POSITION_COLOR_LIGHT) return 6;
        if (format == VertexFormats.POSITION_TEXTURE) return 7;
        if (format == VertexFormats.POSITION_TEXTURE_COLOR) return 8;
        if (format == VertexFormats.POSITION_COLOR_TEXTURE_LIGHT) return 9;
        if (format == VertexFormats.POSITION_TEXTURE_LIGHT_COLOR) return 10;
        if (format == VertexFormats.POSITION_TEXTURE_COLOR_NORMAL) return 11;
        throw new IllegalArgumentException("Unsupported core vertex format "
            + format.getAttributeNames());
    }

    private static int drawMode(VertexFormat.DrawMode mode) {
        return switch (mode) {
            case LINES -> 0;
            case LINE_STRIP -> 1;
            case DEBUG_LINES -> 2;
            case DEBUG_LINE_STRIP -> 3;
            case TRIANGLES -> 4;
            case TRIANGLE_STRIP -> 5;
            case TRIANGLE_FAN -> 6;
            case QUADS -> 7;
        };
    }

    private static int nativeDrawMode(VertexFormat.DrawMode mode) {
        return switch (mode) {
            case LINES, TRIANGLE_FAN -> drawMode(VertexFormat.DrawMode.TRIANGLES);
            case LINE_STRIP -> drawMode(VertexFormat.DrawMode.TRIANGLE_STRIP);
            default -> drawMode(mode);
        };
    }

    private static int indexType(VertexFormat.IndexType type) {
        return switch (type) {
            case SHORT -> 0;
            case INT -> 1;
        };
    }

    private static int align(int value, int alignment) {
        return Math.addExact(value, alignment - 1) / alignment * alignment;
    }

    private record CapturedShader(String id, CompiledShader.Type type, String source) {
    }

    private static final class ProgramInfo {
        private final CapturedShader vertex;
        private final CapturedShader fragment;
        private final VertexFormat format;
        private final Map<VertexFormat.DrawMode, Integer> shaderIds =
            new EnumMap<>(VertexFormat.DrawMode.class);
        private final Map<String, Integer> samplerTextures = new HashMap<>();
        private List<ShaderProgramDefinition.Uniform> uniformDefinitions = List.of();
        private List<ShaderProgramDefinition.Sampler> samplerDefinitions = List.of();
        private UniformLayout layout;

        private ProgramInfo(CapturedShader vertex, CapturedShader fragment,
            VertexFormat format) {
            this.vertex = vertex;
            this.fragment = fragment;
            this.format = format;
        }
    }

    private enum UniformKind {
        INT,
        FLOAT,
        MATRIX,
        SAMPLER
    }

    private record FieldShape(String glslType, UniformKind kind, int alignment, int size,
                              int componentCount, int matrixDimension) {
    }

    private record UniformField(String name, String glslType, UniformKind kind, int offset,
                                int componentCount, int matrixDimension, int samplerIndex) {
    }

    private record UniformLayout(List<UniformField> fields, int size) {
    }

    private record RegisteredProgram(UniformLayout layout, int shaderId) {
    }

    private record MaterializedBuffers(int vertexId, int indexId) {
    }

    private static final class PersistentVertexBuffer {
        private final int vertexCount;
        private final int indexCount;
        private final int indexType;
        private final VertexFormat.DrawMode drawMode;
        private final VertexFormat vertexFormat;
        private byte[] vertexBytes;
        private byte[] indexBytes;
        private int vertexId;
        private int indexId;

        private PersistentVertexBuffer(int vertexCount, int indexCount, int indexType,
            VertexFormat.DrawMode drawMode, VertexFormat vertexFormat, byte[] vertexBytes,
            byte[] indexBytes) {
            this.vertexCount = vertexCount;
            this.indexCount = indexCount;
            this.indexType = indexType;
            this.drawMode = drawMode;
            this.vertexFormat = vertexFormat;
            this.vertexBytes = vertexBytes;
            this.indexBytes = indexBytes;
        }
    }

    private record UploadedIndexBuffer(int id, int indexCount) {
    }
}
