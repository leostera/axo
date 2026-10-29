#ifndef AXO_SQUISHY_H
#define AXO_SQUISHY_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A squishy 3D Axo: a Bullet soft body made from a closed triangle mesh, with air inside it
/// (pressure) and a memory of its shape (pose matching), so it dents, stretches, wobbles and
/// blows up, and comes back. Model space, in points: x right, y up, z towards the viewer.
typedef struct AxoSquishy AxoSquishy;

/// From `vertex_count` vertices (x, y, z each) and `triangle_count` triangles (three vertex
/// indices each, counterclockwise seen from outside), at rest.
AxoSquishy *axo_squishy_create(const float *vertices, int32_t vertex_count, const int32_t *triangles,
                               int32_t triangle_count);
void axo_squishy_destroy(AxoSquishy *squishy);

/// Where each vertex is now (x, y, z each), in the mesh's order.
void axo_squishy_positions(const AxoSquishy *squishy, float *xyz);

/// Runs it `seconds` on (in fixed steps).
void axo_squishy_step(AxoSquishy *squishy, float seconds);

/// How blown up it is: 1 is as made, more pushes it out from inside.
void axo_squishy_set_inflation(AxoSquishy *squishy, float inflation);

/// A jab at (`x`, `y`), seen from the front: the part of it under there is pushed in.
void axo_squishy_poke(AxoSquishy *squishy, float x, float y);

/// Takes hold of the part of it under (`x`, `y`), seen from the front; the hold then follows
/// `axo_squishy_pull_to`, stretching it, until `axo_squishy_let_go`.
void axo_squishy_grab(AxoSquishy *squishy, float x, float y);
void axo_squishy_pull_to(AxoSquishy *squishy, float x, float y);
void axo_squishy_let_go(AxoSquishy *squishy);

/// What carries it (its window) sped up by (`dx`, `dy`) points a second. Held (`axo_squishy_grab`),
/// the held part keeps up and the rest lags behind, stretching and wobbling the way a jelly does.
void axo_squishy_jolt(AxoSquishy *squishy, float dx, float dy);

/// It hit the ground at `speed` points a second: its bottom stops, the rest keeps going, and it
/// squashes against the ground and springs back. It is on the ground from then until
/// `axo_squishy_lift`.
void axo_squishy_land(AxoSquishy *squishy, float speed);

/// Off the ground (picked up, or thrown): nothing under it.
void axo_squishy_lift(AxoSquishy *squishy);

/// How far its vertices are, on average, from where its shape would have them: 0 at rest.
float axo_squishy_wobble(const AxoSquishy *squishy);

#ifdef __cplusplus
}
#endif

#endif
