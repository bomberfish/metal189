package metal189.shim;

public final class ARBOcclusionQuery {
    private ARBOcclusionQuery() {}
    public static int glGenQueriesARB() { return 1; }
    public static void glBeginQueryARB(int t, int id) {}
    public static void glEndQueryARB(int t) {}
    public static int glGetQueryObjectiARB(int id, int p) { return 1; }
}
