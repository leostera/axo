# @axo/mascot

The animated Axo axolotl. `src/` writes `assets/mascot/axo.riv` directly, with no Rive editor:
the drawing is traced from `assets/axo-logo-original.jpeg` in code, and `src/riv.ts` encodes Rive's
runtime format (type and property keys from rive-runtime's generated `*_base.hpp` headers).

```bash
npm run build     # regenerate assets/mascot/axo.riv
npm run preview   # http://127.0.0.1:4177, every artboard in the Rive web runtime
npm test          # types, committed file up to date, encoding, and a headless Chrome run
```

## Contract with the apps (`MascotContract` in `src/mascot.ts`)

| Artboard | Use |
| --- | --- |
| `Icon` | The macOS app icon (rounded square at 80% of a 1024 canvas); replaces the Dock icon. |
| `Face` | The axolotl alone, in colour, for in-app and web use. |
| `Mark` | Black outlines only, drawn as a template image in the menu bar. |
| `Loader` | A square with room to spin, for loading. |

Each artboard runs the `Mascot` state machine, in layers (a later layer wins a property both key):

| Layer | Behaviour | Inputs |
| --- | --- | --- |
| Look, Look Y | Looks around on its own; follows a point while `tracking`. | `tracking`, `lookX`, `lookY` (-100 to 100) |
| Eyes | Random waits of 2, 4 or 7 s, then a blink or (1 in 5) a double blink. | `blink` |
| Hands (`Face` only) | Hands come up over the eyes. | `covering` |
| Loading | Gills flutter and Axo bobs; on `Loader` it also hops and spins. | `loading` |
| Reactions | `poke`: "oh!", then a giggle. `annoyed`: a shake and a frown. | `poke`, `annoyed` |

These are state machine inputs, which the web runtime and the Apple runtime's `RiveViewModel` take;
Rive's newer Apple API expects data binding instead, which the generator does not write yet.

On the Mac, `AxoMascot` (apple/AxoMac) plays `Mark` and `Icon` offscreen through
`AxoMascotRive` and publishes the frames as images. Earlier objects in an artboard draw on top.
