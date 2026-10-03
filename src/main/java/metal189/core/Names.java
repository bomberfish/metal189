package metal189.core;

/** Chooses between SRG (production) and MCP (dev) member names. */
public final class Names {
    private Names() {}

    /** True when running against a reobfuscated (SRG-named) Minecraft. */
    public static boolean obfuscated = true;

    public static String n(String mcp, String srg) { return obfuscated ? srg : mcp; }

    public static boolean is(String name, String mcp, String srg) { return name.equals(mcp) || name.equals(srg); }
}
