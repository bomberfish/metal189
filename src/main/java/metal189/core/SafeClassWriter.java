package metal189.core;

import java.io.IOException;
import java.io.InputStream;
import net.minecraft.launchwrapper.Launch;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;

/**
 * ClassWriter whose common-superclass lookup reads class bytes instead of
 * loading classes (loading from inside a transformer can deadlock or load
 * untransformed versions).
 */
final class SafeClassWriter extends ClassWriter {
    SafeClassWriter(int flags) { super(flags); }

    @Override
    protected String getCommonSuperClass(String a, String b) {
        if (a.equals(b)) return a;
        if ("java/lang/Object".equals(a) || "java/lang/Object".equals(b)) return "java/lang/Object";
        java.util.Set<String> chain = new java.util.HashSet<String>();
        for (String c = a; c != null; c = superOf(c)) chain.add(c);
        for (String c = b; c != null; c = superOf(c)) if (chain.contains(c)) return c;
        return "java/lang/Object";
    }

    private static String superOf(String internal) {
        if ("java/lang/Object".equals(internal)) return null;
        try {
            byte[] bytes = Launch.classLoader != null ? Launch.classLoader.getClassBytes(internal.replace('/', '.')) : null;
            if (bytes == null) {
                InputStream in = ClassLoader.getSystemResourceAsStream(internal + ".class");
                if (in == null) return "java/lang/Object";
                try {
                    return new ClassReader(in).getSuperName();
                } finally {
                    in.close();
                }
            }
            return new ClassReader(bytes).getSuperName();
        } catch (IOException e) {
            return "java/lang/Object";
        }
    }
}
