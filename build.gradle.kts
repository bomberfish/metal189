plugins {
    java
    id("gg.essential.loom") version "0.10.0.+"
    id("dev.architectury.architectury-pack200") version "0.1.3"
}

group = "metal189"
version = "0.2.0-pre"

java {
    toolchain.languageVersion.set(JavaLanguageVersion.of(8))
}

loom {
    forge {
        pack200Provider.set(dev.architectury.pack200.java.Pack200Adapter())
    }
}

repositories {
    mavenCentral()
    maven("https://repo.essential.gg/repository/maven-public")
}

dependencies {
    minecraft("com.mojang:minecraft:1.8.9")
    mappings("de.oceanlabs.mcp:mcp_stable:22-1.8.9")
    forge("net.minecraftforge:forge:1.8.9-11.15.1.1902-1.8.9")
}

tasks.withType<JavaCompile> {
    options.encoding = "UTF-8"
}

// Native library + compiled shader library, built by native/Makefile.
val buildNative by tasks.registering(Exec::class) {
    workingDir = file("native")
    commandLine("make", "-j8")
    inputs.dir("native/src")
    inputs.dir("native/shaders")
    inputs.file("native/Makefile")
    outputs.file("native/build/libmetal189.dylib")
    outputs.file("native/build/metal189.metallib")
}

tasks.processResources {
    dependsOn(buildNative)
    from("native/build/libmetal189.dylib") { into("natives") }
    from("native/build/metal189.metallib") { into("natives") }
    from("native/shaders") { into("shaders") }
    inputs.property("version", project.version)
    filesMatching("mcmod.info") {
        expand("version" to project.version)
    }
}

tasks.jar {
    archiveClassifier.set("dev")
    manifest.attributes(
        "FMLCorePlugin" to "metal189.core.Metal189Plugin",
        "FMLCorePluginContainsFMLMod" to "true",
        "ForceLoadAsMod" to "true",
        "Implementation-Version" to project.version
    )
}

// Loom's remapJar produces an empty jar under this Gradle version, so the
// release jar is reobfuscated (MCP -> SRG) by tools/reobf.sh instead.
tasks.remapJar { enabled = false }

val reobfJar by tasks.registering(Exec::class) {
    dependsOn(tasks.jar)
    val input = tasks.jar.flatMap { it.archiveFile }
    val output = layout.buildDirectory.file("libs/metal189-${project.version}.jar")
    inputs.file(input)
    inputs.file("tools/remap/Remap.java")
    inputs.file("tools/reobf.sh")
    outputs.file(output)
    commandLine("tools/reobf.sh", input.get().asFile.absolutePath, output.get().asFile.absolutePath)
}

tasks.build { dependsOn(reobfJar) }

// Experimental iOS jar (for launchers such as PojavLauncher): the release jar with the iOS
// native library and shader library instead of the macOS ones. Not part of `build`:
// ./gradlew iosJar  ->  build/libs/metal189-<version>-ios.jar
val buildNativeIos by tasks.registering(Exec::class) {
    workingDir = file("native")
    // IOS_SIGN_IDENTITY=<identity> signs the library for the launcher's team instead of ad-hoc
    val identity = System.getenv("IOS_SIGN_IDENTITY") ?: "-"
    commandLine("make", "-j8", "ios", "IOS_SIGN_IDENTITY=$identity")
    inputs.property("signIdentity", identity)
    inputs.dir("native/src")
    inputs.dir("native/shaders")
    inputs.file("native/Makefile")
    outputs.file("native/build-ios/libmetal189.dylib")
    outputs.file("native/build-ios/metal189.metallib")
}

val iosJar by tasks.registering(Zip::class) {
    dependsOn(reobfJar, buildNativeIos)
    archiveFileName.set("metal189-${project.version}-ios.jar")
    destinationDirectory.set(layout.buildDirectory.dir("libs"))
    from(reobfJar.map { zipTree(it.outputs.files.singleFile) }) { exclude("natives/**") }
    from("native/build-ios/libmetal189.dylib") { into("natives") }
    from("native/build-ios/metal189.metallib") { into("natives") }
    // tells Native.locate to unpack inside the app's container (sandbox)
    from(resources.text.fromString("ios\n")) { into("natives"); rename { "platform" } }
}
