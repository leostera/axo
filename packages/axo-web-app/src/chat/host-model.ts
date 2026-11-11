import type { HostModel } from "@axo/protocol";
import type { IconName } from "./icons.tsx";

/** The shape of Mac a host is, to show it by. */
export type HostFamily = "laptop" | "studio" | "mini" | "desktop" | "tower";

const byName: Array<[string, HostFamily]> = [
  ["MacBook", "laptop"], ["Mac Studio", "studio"], ["Mac mini", "mini"], ["iMac", "desktop"], ["Mac Pro", "tower"],
];
const byIdentifier: Array<[string, HostFamily]> = [
  ["MacBook", "laptop"], ["Macmini", "mini"], ["iMac", "desktop"], ["MacPro", "tower"],
];

/**
 * Read from the model's name, which says it ("Mac Studio"); a Mac without one (an Intel Mac) is
 * read from its identifier ("Macmini8,1"), which says it only before Apple silicon. Null when
 * neither does. As on the phone (`HostModel.family`).
 */
export function hostFamily(model: HostModel | undefined): HostFamily | null {
  if (!model) return null;
  const named = model.name ? byName.find(([prefix]) => model.name!.startsWith(prefix)) : undefined;
  return (named ?? byIdentifier.find(([prefix]) => model.identifier.startsWith(prefix)))?.[1] ?? null;
}

const icons: Record<HostFamily, IconName> = {
  laptop: "laptop", studio: "macStudio", mini: "macMini", desktop: "desktop", tower: "tower",
};

/** The icon a Mac is shown by: its shape, or a laptop when it has not said. */
export function hostIcon(host: { readonly model?: HostModel }): IconName {
  const family = hostFamily(host.model);
  return family ? icons[family] : "laptop";
}
