#ifndef AXO_RUBBER_H
#define AXO_RUBBER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Axo in the menu bar, made of rubber: a LiquidFun elastic soft body, a grid of particles over
/// the icon's rectangle, each held to its place there. Grab it and the particles near the grab
/// follow the pointer while the far side holds on, so it stretches; let go and it springs back,
/// wobbling. Everything is in screen points, y up.
typedef struct AxoRubber AxoRubber;

/// A sheet over the rectangle (`x`, `y`, `width`, `height`), at rest.
AxoRubber *axo_rubber_create(float x, float y, float width, float height);
void axo_rubber_destroy(AxoRubber *rubber);

/// The grid: `columns` x `rows` particles, row by row from the bottom left.
int32_t axo_rubber_columns(const AxoRubber *rubber);
int32_t axo_rubber_rows(const AxoRubber *rubber);
/// Where each particle is now (x, y pairs, `columns * rows` of them), in the grid's order.
void axo_rubber_points(const AxoRubber *rubber, float *xy);

/// Takes hold of it at (`x`, `y`), on the icon; the grab then follows `axo_rubber_move`.
void axo_rubber_grab(AxoRubber *rubber, float x, float y);
void axo_rubber_move(AxoRubber *rubber, float x, float y);
/// Lets go: it springs back.
void axo_rubber_let_go(AxoRubber *rubber);
/// How far the grabbed part has been pulled from its place, in points.
float axo_rubber_stretch(const AxoRubber *rubber);
/// Not held, and back in its place, still.
bool axo_rubber_at_rest(const AxoRubber *rubber);

/// Runs it `seconds` on (in fixed steps).
void axo_rubber_step(AxoRubber *rubber, float seconds);

#ifdef __cplusplus
}
#endif

#endif
