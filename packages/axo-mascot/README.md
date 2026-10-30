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

Each artboard runs the `Mascot` state machine: random waits of 2, 4 or 7 seconds, then a blink
(or, one time in five, a double blink). The `blink` trigger blinks on demand; the Rive web runtime
exposes it, while the Apple runtime's newer API expects data binding instead (not written yet).

On the Mac, `AxoMascot` (apple/AxoMac) plays `Mark` and `Icon` offscreen through
`AxoMascotRive` and publishes the frames as images. Earlier objects in an artboard draw on top.
