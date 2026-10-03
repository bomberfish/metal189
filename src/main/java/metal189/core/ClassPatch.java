package metal189.core;

import org.objectweb.asm.tree.ClassNode;

/** A targeted modification of one game class. */
public interface ClassPatch {
    /** @return true if the class was modified */
    boolean apply(ClassNode cn);

    /** Whether the patch changes control flow and needs stack map frames recomputed. */
    boolean needsFrames();
}
