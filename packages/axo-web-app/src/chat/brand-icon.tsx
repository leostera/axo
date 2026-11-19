import pi from "@axo/assets/brands/BrandLogos.xcassets/agent-pi.imageset/agent-pi.svg";
import codex from "@axo/assets/brands/BrandLogos.xcassets/agent-codex.imageset/agent-codex.svg";
import opencode from "@axo/assets/brands/BrandLogos.xcassets/agent-opencode.imageset/agent-opencode.svg";
import claude from "@axo/assets/brands/BrandLogos.xcassets/agent-claude-code.imageset/agent-claude-code.svg";
import linux from "@axo/assets/brands/BrandLogos.xcassets/host-linux.imageset/host-linux.svg";
import windows from "@axo/assets/brands/BrandLogos.xcassets/host-windows.imageset/host-windows.svg";

import cloud from "@axo/assets/brands/BrandLogos.xcassets/host-cloud.imageset/host-cloud.svg";

const logos = { pi, codex, opencode, "claude-code": claude, linux, windows, cloud };
export function BrandIcon({ name, size = 16 }: { name: keyof typeof logos; size?: number }) {
  if (name === "pi") return <img src={logos[name]} width={size} height={size} alt="" aria-hidden="true" data-brand={name} />;
  return <span aria-hidden="true" data-brand={name} style={{ width: size, height: size, display: "inline-block", flexShrink: 0,
    backgroundColor: "currentColor", maskImage: `url("${logos[name]}")`, maskSize: "contain", maskRepeat: "no-repeat", maskPosition: "center" }} />;
}
