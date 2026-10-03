import java.io.*;
import java.util.*;
import java.util.zip.*;
import org.objectweb.asm.*;
import org.objectweb.asm.commons.*;

/**
 * Reobfuscates a mod jar from MCP ("named") member names to SRG names using
 * Loom's mappings-srg-named.srg, resolving inherited members through the
 * Minecraft/Forge class hierarchy.
 *
 * usage: Remap in.jar out.jar mappings.srg hierarchy.jar...
 */
public class Remap {
    static final Map<String, String> methods = new HashMap<>();  // owner.name desc -> srg
    static final Map<String, String> fields = new HashMap<>();   // owner.name -> srg
    static final Map<String, List<String>> parents = new HashMap<>();

    public static void main(String[] a) throws Exception {
        try (BufferedReader r = new BufferedReader(new FileReader(a[2]))) {
            String l;
            while ((l = r.readLine()) != null) {
                String[] p = l.split(" ");
                if (l.startsWith("MD: ")) {
                    String srg = p[1].substring(p[1].lastIndexOf('/') + 1);
                    String named = p[3];
                    int s = named.lastIndexOf('/');
                    methods.put(named.substring(0, s) + "." + named.substring(s + 1) + " " + p[4], srg);
                } else if (l.startsWith("FD: ")) {
                    String srg = p[1].substring(p[1].lastIndexOf('/') + 1);
                    String named = p[2];
                    int s = named.lastIndexOf('/');
                    fields.put(named.substring(0, s) + "." + named.substring(s + 1), srg);
                }
            }
        }
        for (int i = 3; i < a.length; i++) readHierarchy(new File(a[i]));
        Remapper rm = new Remapper() {
            @Override public String mapMethodName(String owner, String name, String desc) {
                String r = findMethod(owner, name, desc, new HashSet<String>());
                return r != null ? r : name;
            }
            @Override public String mapFieldName(String owner, String name, String desc) {
                String r = findField(owner, name, new HashSet<String>());
                return r != null ? r : name;
            }
        };
        try (ZipInputStream in = new ZipInputStream(new FileInputStream(a[0]));
             ZipOutputStream out = new ZipOutputStream(new FileOutputStream(a[1]))) {
            ZipEntry e;
            while ((e = in.getNextEntry()) != null) {
                byte[] data = readAll(in);
                if (e.getName().endsWith(".class")) {
                    ClassReader cr = new ClassReader(data);
                    ClassWriter cw = new ClassWriter(0);
                    cr.accept(new RemappingClassAdapter(cw, rm), ClassReader.EXPAND_FRAMES);
                    data = cw.toByteArray();
                }
                ZipEntry o = new ZipEntry(e.getName());
                o.setTime(e.getTime());
                out.putNextEntry(o);
                out.write(data);
                out.closeEntry();
            }
        }
    }

    static String findMethod(String owner, String name, String desc, Set<String> seen) {
        if (!seen.add(owner)) return null;
        String r = methods.get(owner + "." + name + " " + desc);
        if (r != null) return r;
        for (String p : parents.getOrDefault(owner, Collections.<String>emptyList())) {
            r = findMethod(p, name, desc, seen);
            if (r != null) return r;
        }
        return null;
    }

    static String findField(String owner, String name, Set<String> seen) {
        if (!seen.add(owner)) return null;
        String r = fields.get(owner + "." + name);
        if (r != null) return r;
        for (String p : parents.getOrDefault(owner, Collections.<String>emptyList())) {
            r = findField(p, name, seen);
            if (r != null) return r;
        }
        return null;
    }

    static void readHierarchy(File jar) throws IOException {
        try (ZipInputStream in = new ZipInputStream(new FileInputStream(jar))) {
            ZipEntry e;
            while ((e = in.getNextEntry()) != null) {
                if (!e.getName().endsWith(".class")) continue;
                ClassReader cr = new ClassReader(readAll(in));
                List<String> ps = new ArrayList<>();
                if (cr.getSuperName() != null) ps.add(cr.getSuperName());
                Collections.addAll(ps, cr.getInterfaces());
                parents.put(cr.getClassName(), ps);
            }
        }
    }

    static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
        return b.toByteArray();
    }
}
