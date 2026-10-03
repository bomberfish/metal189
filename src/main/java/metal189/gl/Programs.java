package metal189.gl;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import metal189.engine.Native;

/**
 * GLSL shader/program objects. Vanilla only uses GLSL for post-processing
 * (ShaderGroup); sources are kept so the engine can map known programs to
 * native implementations. Compilation and linking always "succeed".
 */
public final class Programs {
    private Programs() {}

    public static final class Shader {
        final int type;
        String source = "";
        Shader(int type) { this.type = type; }
    }

    public static final class Program {
        final Map<String, Integer> uniforms = new LinkedHashMap<String, Integer>();
        final Map<String, Integer> attributes = new LinkedHashMap<String, Integer>();
        String vertexSource = "", fragmentSource = "";
        boolean warned;
    }

    private static final HashMap<Integer, Object> objects = new HashMap<Integer, Object>();
    private static int nextId = 1;
    public static int current;
    private static final Pattern UNIFORM = Pattern.compile("uniform\\s+\\w+\\s+(\\w+)");
    private static final Pattern ATTRIBUTE = Pattern.compile("(?:attribute|in)\\s+\\w+\\s+(\\w+)\\s*;");

    public static int createShader(int type) { int id = nextId++; objects.put(id, new Shader(type)); return id; }
    public static int createProgram() { int id = nextId++; objects.put(id, new Program()); return id; }
    public static void delete(int id) { objects.remove(id); if (current == id) current = 0; }

    public static void shaderSource(int id, ByteBuffer src) {
        Object o = objects.get(id);
        if (!(o instanceof Shader) || src == null) return;
        byte[] b = new byte[src.remaining()];
        src.duplicate().get(b);
        ((Shader) o).source = new String(b, StandardCharsets.UTF_8);
    }

    public static void shaderSource(int id, CharSequence src) {
        Object o = objects.get(id);
        if (o instanceof Shader) ((Shader) o).source = src.toString();
    }

    public static void attach(int program, int shader) {
        Object p = objects.get(program), s = objects.get(shader);
        if (!(p instanceof Program) || !(s instanceof Shader)) return;
        Shader sh = (Shader) s;
        if (sh.type == 0x8B31 /* GL_VERTEX_SHADER */) ((Program) p).vertexSource = sh.source;
        else ((Program) p).fragmentSource = sh.source;
    }

    public static void link(int program) {
        Object o = objects.get(program);
        if (!(o instanceof Program)) return;
        Program p = (Program) o;
        int loc = 0;
        for (String src : new String[] {p.vertexSource, p.fragmentSource}) {
            Matcher m = UNIFORM.matcher(src);
            while (m.find()) if (!p.uniforms.containsKey(m.group(1))) p.uniforms.put(m.group(1), loc++);
        }
        int aloc = 0;
        Matcher m = ATTRIBUTE.matcher(p.vertexSource);
        while (m.find()) if (!p.attributes.containsKey(m.group(1))) p.attributes.put(m.group(1), aloc++);
    }

    public static void use(int program) { current = program; }

    public static int getUniformLocation(int program, CharSequence name) {
        Object o = objects.get(program);
        if (!(o instanceof Program)) return -1;
        Integer i = ((Program) o).uniforms.get(name.toString());
        return i == null ? -1 : i;
    }

    public static int getAttribLocation(int program, CharSequence name) {
        Object o = objects.get(program);
        if (!(o instanceof Program)) return -1;
        Integer i = ((Program) o).attributes.get(name.toString());
        return i == null ? -1 : i;
    }

    /** Status queries: compile/link always succeed. */
    public static int getParameter(int id, int pname) {
        switch (pname) {
            case 0x8B81: /* COMPILE_STATUS */ case 0x8B82: /* LINK_STATUS */ case 0x8B83: /* VALIDATE_STATUS */ return 1;
            case 0x8B84: /* INFO_LOG_LENGTH */ return 0;
            case 0x8B4F: /* SHADER_TYPE */ { Object o = objects.get(id); return o instanceof Shader ? ((Shader) o).type : 0; }
            default: return 0;
        }
    }

    /** Draws issued while a GLSL program is bound are not supported yet; report once per program. */
    public static boolean blocksDraw() {
        if (current == 0) return false;
        Object o = objects.get(current);
        if (o instanceof Program && !((Program) o).warned) {
            ((Program) o).warned = true;
            Native.LOG.warn("metal189: skipping draws for GLSL program {} (not yet supported)", current);
        }
        return true;
    }
}
