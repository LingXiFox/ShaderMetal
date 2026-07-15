package com.example.shadermetal.render;

import com.example.shadermetal.proxy.RendererProxy;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Deque;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.PriorityQueue;
import java.util.concurrent.atomic.AtomicBoolean;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientChunkEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientWorldEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents;
import net.minecraft.block.BlockState;
import net.minecraft.client.MinecraftClient;
import net.minecraft.client.render.Camera;
import net.minecraft.client.world.ClientWorld;
import net.minecraft.item.BlockItem;
import net.minecraft.item.ItemStack;
import net.minecraft.registry.Registries;
import net.minecraft.registry.tag.BlockTags;
import net.minecraft.util.Arm;
import net.minecraft.util.Identifier;
import net.minecraft.util.math.BlockPos;
import net.minecraft.util.math.ChunkPos;
import net.minecraft.util.math.Vec3d;
import net.minecraft.world.chunk.ChunkSection;
import net.minecraft.world.chunk.WorldChunk;
import org.joml.Vector3f;
import org.lwjgl.system.MemoryUtil;

public final class RayTracingLightCollector {
    private static final int MAX_LIGHTS = 32;
    private static final int MAX_HELD_LIGHTS = 2;
    private static final int MAX_STATIC_LIGHTS = MAX_LIGHTS - MAX_HELD_LIGHTS;
    private static final int MAX_ORE_LIGHTS = 8;
    private static final int MAX_ORE_SECTIONS_PER_TICK = 1;
    private static final int LIGHT_BYTES = 2 * 4 * Float.BYTES;
    private static final int CHUNK_SEARCH_RADIUS = 7;
    private static final double MAX_DISTANCE_SQUARED = 96.0 * 96.0;
    private static final Comparator<Candidate> LEAST_IMPORTANT_FIRST =
        Comparator.comparingDouble(Candidate::importance);
    private static final Comparator<Candidate> MOST_IMPORTANT_FIRST =
        LEAST_IMPORTANT_FIRST.reversed();
    private static final AtomicBoolean INITIALIZED = new AtomicBoolean();
    private static final Map<Long, ChunkLights> CHUNKS = new HashMap<>();
    private static final List<Light> SELECTED = new ArrayList<>(MAX_STATIC_LIGHTS);
    private static final Deque<OreScanTask> PENDING_ORE_SCANS = new ArrayDeque<>();
    private static final ByteBuffer UPLOAD = ByteBuffer
        .allocateDirect(MAX_LIGHTS * LIGHT_BYTES)
        .order(ByteOrder.nativeOrder());
    private static boolean selectionDirty = true;
    private static double selectionCameraX;
    private static double selectionCameraY;
    private static double selectionCameraZ;
    private static ClientWorld activeWorld;
    private static long worldGeneration;
    private static long nextChunkToken = 1;

    private RayTracingLightCollector() {
    }

    public static void initialize() {
        if (!INITIALIZED.compareAndSet(false, true)) {
            return;
        }
        ClientChunkEvents.CHUNK_LOAD.register(RayTracingLightCollector::loadChunk);
        ClientChunkEvents.CHUNK_UNLOAD.register(RayTracingLightCollector::removeChunk);
        ClientWorldEvents.AFTER_CLIENT_WORLD_CHANGE.register((client, world) ->
            changeWorld(world));
        ClientPlayConnectionEvents.DISCONNECT.register((handler, client) -> clear());
        ClientTickEvents.END_CLIENT_TICK.register(client -> processOreScanBudget());
    }

    public static synchronized void handleBlockUpdate(ClientWorld world, BlockPos pos,
        BlockState state) {
        if (world != activeWorld) {
            return;
        }
        long chunkKey = ChunkPos.toLong(pos.getX() >> 4, pos.getZ() >> 4);
        ChunkLights chunkLights = CHUNKS.get(chunkKey);
        if (chunkLights == null) {
            return;
        }
        chunkLights.direct.remove(pos.asLong());
        if (state.getLuminance() > 0 && !isLava(state) && !isOre(state)) {
            chunkLights.direct.put(pos.asLong(), directLight(pos, state));
        }
        rescanLavaCell(world, chunkLights, pos.getX() >> 2, pos.getY() >> 2,
            pos.getZ() >> 2);
        chunkLights.oreBlocks.remove(pos.asLong());
        if (isOre(state)) {
            chunkLights.oreBlocks.put(pos.asLong(), oreLight(pos, state));
        }
        selectionDirty = true;
    }

    public static synchronized void upload(double cameraX, double cameraY, double cameraZ) {
        double selectionDx = cameraX - selectionCameraX;
        double selectionDy = cameraY - selectionCameraY;
        double selectionDz = cameraZ - selectionCameraZ;
        if (selectionDirty || selectionDx * selectionDx + selectionDy * selectionDy
            + selectionDz * selectionDz >= 16.0) {
            selectImportantLights(cameraX, cameraY, cameraZ);
        }

        UPLOAD.clear();
        int uploadCount = appendHeldLights(cameraX, cameraY, cameraZ);
        for (Light light : SELECTED) {
            if (uploadCount >= MAX_LIGHTS) {
                break;
            }
            putLight(light, cameraX, cameraY, cameraZ);
            uploadCount++;
        }
        UPLOAD.flip();
        RendererProxy.setLocalLights(MemoryUtil.memAddress(UPLOAD), uploadCount);
    }

    public static synchronized void clear() {
        resetState(null);
    }

    private static synchronized void changeWorld(ClientWorld world) {
        resetState(world);
    }

    private static void resetState(ClientWorld world) {
        activeWorld = world;
        worldGeneration = worldGeneration == Long.MAX_VALUE ? 1 : worldGeneration + 1;
        CHUNKS.clear();
        SELECTED.clear();
        PENDING_ORE_SCANS.clear();
        selectionDirty = true;
        UPLOAD.clear();
        RendererProxy.setLocalLights(MemoryUtil.memAddress(UPLOAD), 0);
    }

    private static void selectImportantLights(double cameraX, double cameraY,
        double cameraZ) {
        PriorityQueue<Candidate> direct = new PriorityQueue<>(
            MAX_STATIC_LIGHTS, LEAST_IMPORTANT_FIRST);
        PriorityQueue<Candidate> ores = new PriorityQueue<>(
            MAX_ORE_LIGHTS, LEAST_IMPORTANT_FIRST);
        int cameraChunkX = ((int) Math.floor(cameraX)) >> 4;
        int cameraChunkZ = ((int) Math.floor(cameraZ)) >> 4;
        for (int chunkZ = cameraChunkZ - CHUNK_SEARCH_RADIUS;
             chunkZ <= cameraChunkZ + CHUNK_SEARCH_RADIUS; chunkZ++) {
            for (int chunkX = cameraChunkX - CHUNK_SEARCH_RADIUS;
                 chunkX <= cameraChunkX + CHUNK_SEARCH_RADIUS; chunkX++) {
                ChunkLights chunk = CHUNKS.get(ChunkPos.toLong(chunkX, chunkZ));
                if (chunk == null) {
                    continue;
                }
                appendCandidates(chunk.direct.values(), direct, MAX_STATIC_LIGHTS,
                    cameraX, cameraY, cameraZ);
                appendCandidates(chunk.lavaCells.values(), direct, MAX_STATIC_LIGHTS,
                    cameraX, cameraY, cameraZ);
                appendCandidates(chunk.oreBlocks.values(), ores, MAX_ORE_LIGHTS,
                    cameraX, cameraY, cameraZ);
            }
        }

        int oreLimit = Math.min(MAX_ORE_LIGHTS, ores.size());
        int directLimit = Math.min(MAX_STATIC_LIGHTS - oreLimit, direct.size());
        SELECTED.clear();
        // The secondary path only examines the leading local lights, so real emitters
        // precede ore proxies. The limits still reserve all selected ore slots.
        appendMostImportant(direct, directLimit);
        appendMostImportant(ores, oreLimit);
        selectionCameraX = cameraX;
        selectionCameraY = cameraY;
        selectionCameraZ = cameraZ;
        selectionDirty = false;
    }

    private static synchronized void loadChunk(ClientWorld world, WorldChunk chunk) {
        if (world != activeWorld) {
            return;
        }
        long chunkKey = chunk.getPos().toLong();
        ChunkLights previous = CHUNKS.remove(chunkKey);
        if (previous != null) {
            cancelOreScans(chunkKey, previous.token);
        }
        long chunkToken = nextChunkToken;
        nextChunkToken = nextChunkToken == Long.MAX_VALUE ? 1 : nextChunkToken + 1;
        ChunkLights lights = new ChunkLights(chunk, chunkToken);
        chunk.forEachLightSource((pos, state) -> {
            if (isLava(state)) {
                mergeCell(lights.lavaCells, pos.getX() >> 2, pos.getY() >> 2,
                    pos.getZ() >> 2, directLight(pos, state), 1.10F);
            } else if (!isOre(state)) {
                lights.direct.put(pos.asLong(), directLight(pos, state));
            }
        });

        CHUNKS.put(chunkKey, lights);
        ChunkSection[] sections = chunk.getSectionArray();
        for (int sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
            ChunkSection section = sections[sectionIndex];
            if (section.isEmpty() || !section.hasAny(RayTracingLightCollector::isOre)) {
                continue;
            }
            int startY = world.sectionIndexToCoord(sectionIndex) << 4;
            PENDING_ORE_SCANS.addLast(new OreScanTask(
                worldGeneration, chunkKey, chunkToken, sectionIndex, startY));
        }
        selectionDirty = true;
    }

    private static synchronized void processOreScanBudget() {
        int scannedSections = 0;
        boolean lightsChanged = false;
        while (scannedSections < MAX_ORE_SECTIONS_PER_TICK
            && !PENDING_ORE_SCANS.isEmpty()) {
            OreScanTask task = PENDING_ORE_SCANS.removeFirst();
            ChunkLights lights = CHUNKS.get(task.chunkKey());
            if (task.worldGeneration() != worldGeneration || lights == null ||
                lights.token != task.chunkToken()) {
                continue;
            }
            ChunkSection[] sections = lights.chunk.getSectionArray();
            if (task.sectionIndex() < 0 || task.sectionIndex() >= sections.length) {
                continue;
            }
            scannedSections++;
            lightsChanged = true;
            ChunkSection section = sections[task.sectionIndex()];
            int startX = lights.chunk.getPos().getStartX();
            int startY = task.startY();
            int startZ = lights.chunk.getPos().getStartZ();
            int endY = startY + 16;
            lights.oreBlocks.keySet().removeIf(key -> {
                int y = BlockPos.fromLong(key).getY();
                return y >= startY && y < endY;
            });
            for (int y = 0; y < 16; y++) {
                for (int z = 0; z < 16; z++) {
                    for (int x = 0; x < 16; x++) {
                        BlockState state = section.getBlockState(x, y, z);
                        if (isOre(state)) {
                            BlockPos pos = new BlockPos(
                                startX + x, startY + y, startZ + z);
                            lights.oreBlocks.put(pos.asLong(), oreLight(pos, state));
                        }
                    }
                }
            }
        }
        if (lightsChanged) {
            selectionDirty = true;
        }
    }

    private static synchronized void removeChunk(ClientWorld world, WorldChunk chunk) {
        if (world != activeWorld) {
            return;
        }
        long chunkKey = chunk.getPos().toLong();
        ChunkLights lights = CHUNKS.get(chunkKey);
        if (lights == null || lights.chunk != chunk) {
            return;
        }
        CHUNKS.remove(chunkKey);
        cancelOreScans(chunkKey, lights.token);
        selectionDirty = true;
    }

    private static void cancelOreScans(long chunkKey, long chunkToken) {
        PENDING_ORE_SCANS.removeIf(task ->
            task.worldGeneration() == worldGeneration && task.chunkKey() == chunkKey &&
                task.chunkToken() == chunkToken);
    }

    private static void rescanLavaCell(ClientWorld world, ChunkLights chunk,
        int cellX, int cellY, int cellZ) {
        long cellKey = BlockPos.asLong(cellX, cellY, cellZ);
        chunk.lavaCells.remove(cellKey);
        int startX = cellX << 2;
        int startY = cellY << 2;
        int startZ = cellZ << 2;
        BlockPos.Mutable mutable = new BlockPos.Mutable();
        for (int y = 0; y < 4; y++) {
            for (int z = 0; z < 4; z++) {
                for (int x = 0; x < 4; x++) {
                    mutable.set(startX + x, startY + y, startZ + z);
                    BlockState state = world.getBlockState(mutable);
                    if (isLava(state)) {
                        mergeCell(chunk.lavaCells, cellX, cellY, cellZ,
                            directLight(mutable, state), 1.10F);
                    }
                }
            }
        }
    }

    private static void mergeCell(Map<Long, Light> cells, int cellX, int cellY, int cellZ,
        Light light, float maximumIntensity) {
        long key = BlockPos.asLong(cellX, cellY, cellZ);
        Light previous = cells.get(key);
        if (previous == null) {
            cells.put(key, light);
            return;
        }
        float totalIntensity = previous.intensity() + light.intensity();
        float previousWeight = previous.intensity() / totalIntensity;
        float lightWeight = light.intensity() / totalIntensity;
        cells.put(key, new Light(
            previous.x() * previousWeight + light.x() * lightWeight,
            previous.y() * previousWeight + light.y() * lightWeight,
            previous.z() * previousWeight + light.z() * lightWeight,
            Math.max(previous.radius(), light.radius()),
            previous.red() * previousWeight + light.red() * lightWeight,
            previous.green() * previousWeight + light.green() * lightWeight,
            previous.blue() * previousWeight + light.blue() * lightWeight,
            Math.min(totalIntensity, maximumIntensity)));
    }

    private static void appendCandidates(Iterable<Light> lights,
        PriorityQueue<Candidate> destination, int limit,
        double cameraX, double cameraY, double cameraZ) {
        for (Light light : lights) {
            double dx = light.x() - cameraX;
            double dy = light.y() - cameraY;
            double dz = light.z() - cameraZ;
            double distanceSquared = dx * dx + dy * dy + dz * dz;
            if (distanceSquared <= MAX_DISTANCE_SQUARED) {
                double importance = light.intensity() / (1.0 + distanceSquared);
                if (destination.size() < limit) {
                    destination.add(new Candidate(light, importance));
                } else if (importance > destination.peek().importance()) {
                    destination.poll();
                    destination.add(new Candidate(light, importance));
                }
            }
        }
    }

    private static void appendMostImportant(PriorityQueue<Candidate> candidates, int limit) {
        List<Candidate> ordered = new ArrayList<>(candidates);
        ordered.sort(MOST_IMPORTANT_FIRST);
        for (int index = 0; index < limit; index++) {
            SELECTED.add(ordered.get(index).light());
        }
    }

    private static void putLight(Light light, double cameraX, double cameraY, double cameraZ) {
        UPLOAD.putFloat((float) (light.x() - cameraX));
        UPLOAD.putFloat((float) (light.y() - cameraY));
        UPLOAD.putFloat((float) (light.z() - cameraZ));
        UPLOAD.putFloat(light.radius());
        UPLOAD.putFloat(light.red());
        UPLOAD.putFloat(light.green());
        UPLOAD.putFloat(light.blue());
        UPLOAD.putFloat(light.intensity());
    }

    private static int appendHeldLights(double cameraX, double cameraY, double cameraZ) {
        MinecraftClient client = MinecraftClient.getInstance();
        if (client.player == null) {
            return 0;
        }

        Camera camera = client.gameRenderer.getCamera();
        Vec3d origin = camera.isThirdPerson()
            ? client.player.getCameraPosVec(camera.getLastTickDelta())
            : new Vec3d(cameraX, cameraY, cameraZ);
        Vector3f forward = camera.getHorizontalPlane();
        Vector3f up = camera.getVerticalPlane();
        Vector3f left = camera.getDiagonalPlane();
        float mainSide = client.player.getMainArm() == Arm.RIGHT ? -1.0F : 1.0F;

        int count = appendHeldLight(client.player.getMainHandStack(), origin,
            forward, up, left, mainSide, cameraX, cameraY, cameraZ);
        count += appendHeldLight(client.player.getOffHandStack(), origin,
            forward, up, left, -mainSide, cameraX, cameraY, cameraZ);
        return count;
    }

    private static int appendHeldLight(ItemStack stack, Vec3d origin,
        Vector3f forward, Vector3f up, Vector3f left, float side,
        double cameraX, double cameraY, double cameraZ) {
        LightProfile profile = heldLightProfile(stack);
        if (profile == null) {
            return 0;
        }

        Light light = new Light(
            (float) origin.x + forward.x * 0.34F + up.x * -0.26F
                + left.x * side * 0.28F,
            (float) origin.y + forward.y * 0.34F + up.y * -0.26F
                + left.y * side * 0.28F,
            (float) origin.z + forward.z * 0.34F + up.z * -0.26F
                + left.z * side * 0.28F,
            profile.radius() * 0.86F,
            profile.red(), profile.green(), profile.blue(),
            profile.intensity() * 0.78F);
        putLight(light, cameraX, cameraY, cameraZ);
        return 1;
    }

    private static LightProfile heldLightProfile(ItemStack stack) {
        if (stack.isEmpty()) {
            return null;
        }
        Identifier id = Registries.ITEM.getId(stack.getItem());
        String path = id == null ? "" : id.getPath();
        int luminance = 0;
        if (stack.getItem() instanceof BlockItem blockItem) {
            BlockState state = blockItem.getBlock().getDefaultState();
            if (!isOre(state)) {
                luminance = state.getLuminance();
            }
        } else if (path.equals("lava_bucket")) {
            luminance = 15;
        }
        return luminance > 0 ? directLightProfile(path, luminance) : null;
    }

    private static Light directLight(BlockPos pos, BlockState state) {
        int luminance = Math.max(1, state.getLuminance());
        LightProfile profile = directLightProfile(blockPath(state), luminance);
        return new Light(pos.getX() + 0.5F, pos.getY() + 0.5F, pos.getZ() + 0.5F,
            profile.radius(), profile.red(), profile.green(), profile.blue(),
            profile.intensity());
    }

    private static LightProfile directLightProfile(String path, int luminance) {
        float[] color = lightColor(path);
        float normalized = luminance / 15.0F;
        float radius = 3.25F + (float) Math.sqrt(normalized) * 4.0F;
        float intensity = 0.30F + normalized * 0.65F;

        if (path.contains("soul_")) {
            radius = 5.5F;
            intensity = 0.55F;
        } else if (path.contains("campfire")) {
            radius = 7.5F;
            intensity = 1.05F;
        } else if (path.contains("lava")) {
            radius = 6.75F;
            intensity = 0.85F;
        } else if (path.contains("redstone_lamp")) {
            radius = 7.25F;
            intensity = 0.95F;
        } else if (path.contains("sea_lantern") || path.contains("end_rod")
            || path.contains("beacon")) {
            radius = 6.75F;
            intensity = 0.78F;
        } else if (path.contains("glowstone") || path.contains("shroomlight")
            || path.contains("froglight")) {
            radius = 7.0F;
            intensity = 0.85F;
        } else if (path.contains("torch")) {
            radius = path.contains("redstone") ? 4.75F : 7.25F;
            intensity = path.contains("redstone") ? 0.42F : 0.95F;
        } else if (path.contains("lantern")) {
            radius = 7.0F;
            intensity = 0.95F;
        } else if (path.contains("fire")) {
            radius = 6.5F;
            intensity = 0.75F;
        } else if (path.contains("candle")) {
            radius = 3.5F + normalized * 2.25F;
            intensity = 0.30F + normalized * 0.52F;
        }
        return new LightProfile(radius, color[0], color[1], color[2], intensity);
    }

    private static Light oreLight(BlockPos pos, BlockState state) {
        float[] color = oreColor(state);
        float intensity = oreIntensity(state);
        float radius = 1.8F + intensity * 3.75F;
        return new Light(pos.getX() + 0.5F, pos.getY() + 0.5F, pos.getZ() + 0.5F,
            radius, color[0], color[1], color[2], intensity);
    }

    private static float[] lightColor(String path) {
        if (path.contains("soul_")) return new float[] {0.25F, 0.78F, 1.0F};
        if (path.contains("redstone_lamp")) return new float[] {1.0F, 0.70F, 0.28F};
        if (path.contains("redstone")) return new float[] {1.0F, 0.12F, 0.035F};
        if (path.contains("sea_lantern") || path.contains("end_rod")
            || path.contains("beacon")) return new float[] {0.70F, 0.92F, 1.0F};
        if (path.contains("glowstone") || path.contains("shroomlight")
            || path.contains("froglight")) return new float[] {1.0F, 0.76F, 0.34F};
        if (path.contains("lava")) return new float[] {1.0F, 0.34F, 0.07F};
        if (path.contains("lantern")) return new float[] {1.0F, 0.64F, 0.30F};
        if (path.contains("fire") || path.contains("torch")
            || path.contains("campfire") || path.contains("candle")) {
            return new float[] {1.0F, 0.56F, 0.22F};
        }
        return new float[] {1.0F, 0.82F, 0.60F};
    }

    private static float[] oreColor(BlockState state) {
        if (state.isIn(BlockTags.DIAMOND_ORES)) return new float[] {0.25F, 0.95F, 1.0F};
        if (state.isIn(BlockTags.EMERALD_ORES)) return new float[] {0.15F, 1.0F, 0.35F};
        if (state.isIn(BlockTags.REDSTONE_ORES)) return new float[] {1.0F, 0.10F, 0.03F};
        if (state.isIn(BlockTags.LAPIS_ORES)) return new float[] {0.15F, 0.30F, 1.0F};
        if (state.isIn(BlockTags.GOLD_ORES)) return new float[] {1.0F, 0.75F, 0.15F};
        if (state.isIn(BlockTags.COPPER_ORES)) return new float[] {0.30F, 0.95F, 0.65F};
        if (state.isIn(BlockTags.IRON_ORES)) return new float[] {0.90F, 0.80F, 0.65F};
        return new float[] {0.38F, 0.42F, 0.48F};
    }

    private static float oreIntensity(BlockState state) {
        if (state.isIn(BlockTags.DIAMOND_ORES)) return 0.24F;
        if (state.isIn(BlockTags.EMERALD_ORES)) return 0.23F;
        if (state.isIn(BlockTags.REDSTONE_ORES)) return 0.24F;
        if (state.isIn(BlockTags.LAPIS_ORES)) return 0.20F;
        if (state.isIn(BlockTags.GOLD_ORES)) return 0.19F;
        if (state.isIn(BlockTags.COPPER_ORES)) return 0.16F;
        if (state.isIn(BlockTags.IRON_ORES)) return 0.14F;
        return 0.10F;
    }

    private static boolean isOre(BlockState state) {
        return state.isIn(BlockTags.COAL_ORES) || state.isIn(BlockTags.IRON_ORES)
            || state.isIn(BlockTags.COPPER_ORES) || state.isIn(BlockTags.GOLD_ORES)
            || state.isIn(BlockTags.REDSTONE_ORES) || state.isIn(BlockTags.LAPIS_ORES)
            || state.isIn(BlockTags.DIAMOND_ORES) || state.isIn(BlockTags.EMERALD_ORES);
    }

    private static boolean isLava(BlockState state) {
        return blockPath(state).contains("lava");
    }

    private static String blockPath(BlockState state) {
        Identifier id = Registries.BLOCK.getId(state.getBlock());
        return id == null ? "" : id.getPath();
    }

    private static final class ChunkLights {
        private final WorldChunk chunk;
        private final long token;
        private final Map<Long, Light> direct = new HashMap<>();
        private final Map<Long, Light> lavaCells = new HashMap<>();
        private final Map<Long, Light> oreBlocks = new HashMap<>();

        private ChunkLights(WorldChunk chunk, long token) {
            this.chunk = chunk;
            this.token = token;
        }
    }

    private record Light(float x, float y, float z, float radius,
                         float red, float green, float blue, float intensity) {
    }

    private record LightProfile(float radius, float red, float green, float blue,
                                float intensity) {
    }

    private record Candidate(Light light, double importance) {
    }

    private record OreScanTask(long worldGeneration, long chunkKey, long chunkToken,
                               int sectionIndex, int startY) {
    }
}
