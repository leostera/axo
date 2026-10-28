#ifndef AXO_GOO_H
#define AXO_GOO_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The goo Axo stretches out of the menu bar on: a LiquidFun particle fluid, viscous and with
/// surface tension, held at one end by a small "hand" of particles at the menu bar icon and at
/// the other by one moved with Axo. Everything is in screen points, y up.
typedef struct AxoGoo AxoGoo;

AxoGoo *axo_goo_create(float iconX, float iconY, float axoX, float axoY);
void axo_goo_destroy(AxoGoo *goo);

/// Where Axo, and so its hand, is now.
void axo_goo_move_axo(AxoGoo *goo, float x, float y);
/// Runs the fluid `seconds` on (in fixed steps).
void axo_goo_step(AxoGoo *goo, float seconds);

/// Whether a chain of touching particles still joins the icon to Axo; false once it has snapped.
bool axo_goo_connected(AxoGoo *goo);
/// After the snap: each bit of goo flows back into whichever end it still holds on to, and is
/// gone when it gets there; the icon's end is drawn up into the menu bar, off the top of the
/// screen.
void axo_goo_take_back(AxoGoo *goo);
/// How many fluid particles are left (not counting the hands).
int32_t axo_goo_fluid_count(const AxoGoo *goo);
/// How many fluid particles are joined to the icon (`held[0]`) and to Axo (`held[1]`); while it is
/// still in one piece each counts all of it.
void axo_goo_split(const AxoGoo *goo, int32_t held[2]);

/// The area to draw, in points: x, y, width, height; empty when there is nothing to draw.
void axo_goo_bounds(const AxoGoo *goo, float bounds[4]);
/// Draws it into `pixels` (premultiplied RGBA, `width` x `height`, top row first), which covers
/// the points from (`originX`, `originY`) at `scale` pixels to the point: a metaball surface over
/// the particles, in Axo's white with its dark outline.
void axo_goo_draw(const AxoGoo *goo, uint8_t *pixels, int32_t width, int32_t height, float originX, float originY,
                  float scale);

#ifdef __cplusplus
}
#endif

#endif
