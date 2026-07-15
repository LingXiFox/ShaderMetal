package com.example.shadermetal.render;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import net.minecraft.client.render.VertexFormat;

final class GlslTranslator {
    static final int BINDLESS_TEXTURE_COUNT = 4096;

    private static final Pattern VERSION = Pattern.compile(
        "(?m)^\\s*#version\\s+\\d+[^\\r\\n]*(?:\\R|$)");
    private static final Pattern UNIFORM = Pattern.compile(
        "(?m)^\\s*uniform\\s+([A-Za-z_][A-Za-z0-9_]*)\\s+"
            + "([A-Za-z_][A-Za-z0-9_]*)(?:\\s*\\[[^;]+])?\\s*;\\s*(?:\\R|$)");
    private static final Pattern INTERFACE_VARIABLE = Pattern.compile(
        "(?m)^(\\s*)(?:(flat|smooth|noperspective|centroid|sample)\\s+)?"
            + "(?:layout\\s*\\([^)]*\\)\\s*)?(in|out)\\s+"
            + "([A-Za-z_][A-Za-z0-9_]*)\\s+([A-Za-z_][A-Za-z0-9_]*)"
            + "(\\s*\\[[^;]+])?\\s*;");

    private GlslTranslator() {
    }

    static TranslatedProgram translate(String vertexSource, String fragmentSource,
        VertexFormat vertexFormat, List<UniformDeclaration> declarations) {
        Map<String, UniformDeclaration> declarationsByName = new LinkedHashMap<>();
        for (UniformDeclaration declaration : declarations) {
            UniformDeclaration previous = declarationsByName.putIfAbsent(
                declaration.name(), declaration);
            if (previous != null) {
                throw new IllegalArgumentException(
                    "Duplicate shader uniform declaration " + declaration.name());
            }
        }

        String vertexBody = prepareBody(vertexSource, declarationsByName);
        String fragmentBody = prepareBody(fragmentSource, declarationsByName);
        Map<String, Integer> varyingLocations = collectVertexOutputLocations(vertexBody);

        vertexBody = rewriteInterface(vertexBody, Stage.VERTEX, vertexFormat,
            varyingLocations);
        fragmentBody = rewriteInterface(fragmentBody, Stage.FRAGMENT, vertexFormat,
            varyingLocations);
        vertexBody = vertexBody
            .replaceAll("\\bgl_VertexID\\b", "gl_VertexIndex")
            .replaceAll("\\bgl_InstanceID\\b", "gl_InstanceIndex");

        String header = buildHeader(declarations);
        return new TranslatedProgram(header + vertexBody, header + fragmentBody);
    }

    private static String prepareBody(String source,
        Map<String, UniformDeclaration> declarations) {
        if (source.contains("#moj_import")) {
            throw new IllegalArgumentException(
                "Shader source still contains an unresolved #moj_import directive");
        }

        String withoutVersion = VERSION.matcher(source).replaceAll("");
        Matcher matcher = UNIFORM.matcher(withoutVersion);
        StringBuffer result = new StringBuffer();
        while (matcher.find()) {
            String type = matcher.group(1);
            String name = matcher.group(2);
            UniformDeclaration declaration = declarations.get(name);
            boolean sampler = type.toLowerCase(Locale.ROOT).contains("sampler");
            if (declaration != null && sampler != declaration.sampler()) {
                throw new IllegalArgumentException(
                    "Shader uniform kind disagrees with program definition for " + name);
            }
            // Shared core shaders declare uniforms used only by optional #ifdef paths.
            // OpenGL leaves omitted uniforms at zero; sampler zero selects texture unit 0.
            // Recreate those defaults after removing the non-Vulkan uniform declaration.
            String replacement = declaration == null
                ? defaultUniformDefinition(type, name, sampler, declarations)
                : "";
            matcher.appendReplacement(result, Matcher.quoteReplacement(replacement));
        }
        matcher.appendTail(result);
        return result.toString();
    }

    private static String defaultUniformDefinition(String type, String name,
        boolean sampler, Map<String, UniformDeclaration> declarations) {
        String value;
        if (sampler) {
            UniformDeclaration textureUnitZero = declarations.get("Sampler0");
            value = textureUnitZero != null && textureUnitZero.sampler()
                ? "Sampler0" : "textures[0]";
        } else {
            value = type + "(0)";
        }
        return "#define " + name + " " + value + "\n";
    }

    private static Map<String, Integer> collectVertexOutputLocations(String source) {
        Map<String, Integer> result = new LinkedHashMap<>();
        Matcher matcher = INTERFACE_VARIABLE.matcher(source);
        while (matcher.find()) {
            if (matcher.group(3).equals("out")) {
                result.computeIfAbsent(matcher.group(5), ignored -> result.size());
            }
        }
        return result;
    }

    private static String rewriteInterface(String source, Stage stage,
        VertexFormat vertexFormat, Map<String, Integer> varyingLocations) {
        List<String> attributeNames = vertexFormat.getAttributeNames();
        Map<String, Integer> attributeLocations = new HashMap<>();
        for (int index = 0; index < attributeNames.size(); index++) {
            attributeLocations.put(attributeNames.get(index), index);
        }

        Set<Integer> usedAttributeLocations = Set.copyOf(attributeLocations.values());
        int[] nextAttributeLocation = {0};
        int[] nextFragmentOutputLocation = {0};
        int[] nextVaryingLocation = {varyingLocations.size()};
        Matcher matcher = INTERFACE_VARIABLE.matcher(source);
        StringBuffer result = new StringBuffer();
        while (matcher.find()) {
            String qualifier = matcher.group(2);
            String direction = matcher.group(3);
            String name = matcher.group(5);
            int location;
            if (stage == Stage.VERTEX && direction.equals("in")) {
                Integer known = attributeLocations.get(name);
                if (known != null) {
                    location = known;
                } else {
                    while (usedAttributeLocations.contains(nextAttributeLocation[0])) {
                        nextAttributeLocation[0]++;
                    }
                    location = nextAttributeLocation[0]++;
                }
            } else if (stage == Stage.FRAGMENT && direction.equals("out")) {
                location = nextFragmentOutputLocation[0]++;
            } else {
                Integer known = varyingLocations.get(name);
                if (known == null) {
                    known = nextVaryingLocation[0]++;
                    varyingLocations.put(name, known);
                }
                location = known;
            }

            StringBuilder replacement = new StringBuilder(matcher.group(1));
            replacement.append("layout(location = ").append(location).append(") ");
            if (qualifier != null) {
                replacement.append(qualifier).append(' ');
            }
            replacement.append(direction).append(' ').append(matcher.group(4)).append(' ')
                .append(name);
            if (matcher.group(6) != null) {
                replacement.append(matcher.group(6));
            }
            replacement.append(';');
            matcher.appendReplacement(result, Matcher.quoteReplacement(replacement.toString()));
        }
        matcher.appendTail(result);
        return result.toString();
    }

    private static String buildHeader(List<UniformDeclaration> declarations) {
        StringBuilder header = new StringBuilder(512);
        header.append("#version 460\n")
            .append("#extension GL_EXT_nonuniform_qualifier : require\n")
            .append("layout(set = 0, binding = 0) uniform sampler2D textures[")
            .append(BINDLESS_TEXTURE_COUNT).append("];\n")
            .append("layout(std140, set = 1, binding = 0) uniform DrawUniforms {\n");

        List<UniformDeclaration> fields = new ArrayList<>(declarations);
        if (fields.isEmpty()) {
            header.append("    uint shadermetalPadding;\n");
        } else {
            for (UniformDeclaration declaration : fields) {
                header.append("    ").append(declaration.glslType()).append(' ')
                    .append(declaration.name()).append(";\n");
            }
        }
        header.append("} drawUniforms;\n");
        for (UniformDeclaration declaration : fields) {
            header.append("#define ").append(declaration.name()).append(' ');
            if (declaration.sampler()) {
                header.append("textures[nonuniformEXT(drawUniforms.")
                    .append(declaration.name()).append(")]\n");
            } else {
                header.append("drawUniforms.").append(declaration.name()).append('\n');
            }
        }
        header.append("#line 1\n");
        return header.toString();
    }

    record UniformDeclaration(String name, String glslType, boolean sampler) {
    }

    record TranslatedProgram(String vertexSource, String fragmentSource) {
    }

    private enum Stage {
        VERTEX,
        FRAGMENT
    }
}
