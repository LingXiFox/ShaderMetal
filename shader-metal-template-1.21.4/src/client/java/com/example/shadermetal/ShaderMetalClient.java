package com.example.shadermetal;

import com.example.shadermetal.proxy.RendererProxy;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.loader.api.FabricLoader;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class ShaderMetalClient implements ClientModInitializer {
    public static final String MOD_ID = "shadermetal";
    public static final Logger LOGGER = LoggerFactory.getLogger(MOD_ID);

    private static final String NATIVE_RESOURCE =
        "/natives/macos-arm64/libshadermetal.dylib";
    private static final AtomicBoolean LIBRARY_LOADED = new AtomicBoolean();

    @Override
    public void onInitializeClient() {
        requireSupportedPlatform();
        if (!LIBRARY_LOADED.compareAndSet(false, true)) {
            return;
        }

        Path runtimeDirectory = FabricLoader.getInstance().getGameDir().resolve(MOD_ID);
        try {
            Files.createDirectories(runtimeDirectory);
            Path library = extractNativeLibrary(runtimeDirectory.resolve("native"));
            System.load(library.toAbsolutePath().toString());
            RendererProxy.initFolderPath(runtimeDirectory.toAbsolutePath().toString());
            LOGGER.info("Loaded ShaderMetal native library from {}", library);
        } catch (IOException | UnsatisfiedLinkError exception) {
            LIBRARY_LOADED.set(false);
            throw new IllegalStateException("Unable to load ShaderMetal native renderer", exception);
        }
    }

    public static boolean isLibraryLoaded() {
        return LIBRARY_LOADED.get();
    }

    private static Path extractNativeLibrary(Path nativeDirectory) throws IOException {
        Files.createDirectories(nativeDirectory);
        Path target = nativeDirectory.resolve("libshadermetal.dylib");
        Path temporary = Files.createTempFile(nativeDirectory, "libshadermetal-", ".tmp");

        try (InputStream input = ShaderMetalClient.class.getResourceAsStream(NATIVE_RESOURCE)) {
            if (input == null) {
                throw new IOException("Missing native resource " + NATIVE_RESOURCE);
            }
            Files.copy(input, temporary, StandardCopyOption.REPLACE_EXISTING);
            try {
                Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING);
            }
            return target;
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    private static void requireSupportedPlatform() {
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        String arch = System.getProperty("os.arch", "").toLowerCase(Locale.ROOT);
        boolean macOS = os.contains("mac");
        boolean arm64 = arch.equals("aarch64") || arch.equals("arm64");
        if (!macOS || !arm64) {
            throw new IllegalStateException(
                "ShaderMetal requires macOS on Apple Silicon; detected " + os + "/" + arch);
        }
    }
}
