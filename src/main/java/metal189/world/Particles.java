package metal189.world;

import metal189.config.Config;
import net.minecraft.client.particle.EntityFX;
import net.minecraft.client.particle.EntitySuspendFX;

/** Particle filters for the advanced pipeline. */
public final class Particles {
    private Particles() {}

    /**
     * Head of EffectRenderer.addEffect: true drops the particle. In shaders mode the water
     * is drawn before particles, so vanilla's suspended particles inside water would show
     * through the surface as crisp squares instead of being hidden by it.
     */
    public static boolean cancel(EntityFX fx) {
        return Config.hideUnderwaterParticles && Pipeline.advanced() && fx instanceof EntitySuspendFX;
    }
}
