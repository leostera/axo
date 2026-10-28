# LiquidFun

Google's particle-fluid fork of Box2D, for the goo Axo stretches out of the menu bar on
(`apple/AxoGoo`). Vendored from https://github.com/google/liquidfun at
`7f20402173fd143a3988c921bc384459c6a858f2` (the `liquidfun/Box2D/Box2D` directory), without its
documentation, CMake files and NEON assembly (`b2ParticleAssembly.neon.s`, unused without
`LIQUIDFUN_SIMD_NEON`). zlib licence: `LICENSE`.

## Changes

Already applied to the sources here; the diffs are kept in `patches/` so the copy can be
refreshed.

### 0001-viscoelastic-springs.patch

Spring particles' pair bonds become viscoelastic, after Clavet et al. 2005, "Particle-based
Viscoelastic Fluid Simulation": `b2ParticleSystemDef.springYield`, `springPlasticity` and
`springBreak`. A bond stretched past its yield flows (its rest length grows), and one whose
particles are more than `springBreak` particle diameters apart (times the pair's strength, so
stronger bonds hold further) breaks. That is what lets goo be drawn out into a strand
and snap. All three default to zero, which leaves LiquidFun's springs as they were.
