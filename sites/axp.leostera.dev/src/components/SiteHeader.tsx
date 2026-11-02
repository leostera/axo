import { Badge, Link } from "@cloudflare/kumo";
import { SCHEMA_PATH, TREE_URL, VERSION } from "../lib/site";

const NAV = [
  { href: "/", label: "Specification" },
  { href: "/extensions/", label: "Extensions" },
  { href: "/examples/", label: "Examples" },
  { href: SCHEMA_PATH, label: "Schema" },
] as const;

export function SiteHeader({ current }: { current: string }) {
  return (
    <header className="sticky top-0 z-10 border-b border-kumo-hairline bg-kumo-base/90 backdrop-blur-sm">
      <div className="mx-auto flex h-14 max-w-6xl items-center gap-6 px-5">
        <a href="/" className="flex items-center gap-2.5 text-kumo-strong no-underline">
          <span className="font-semibold tracking-tight">AXP</span>
          <Badge variant="outline">v{VERSION} draft</Badge>
        </a>
        <nav aria-label="Primary" className="ml-auto flex items-center gap-5 overflow-x-auto text-sm">
          {NAV.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              variant="plain"
              aria-current={current === item.href ? "page" : undefined}
              className={
                current === item.href
                  ? "whitespace-nowrap font-medium text-kumo-strong"
                  : "whitespace-nowrap text-kumo-subtle hover:text-kumo-strong"
              }
            >
              {item.label}
            </Link>
          ))}
          <Link href={TREE_URL} variant="plain" className="whitespace-nowrap text-kumo-subtle hover:text-kumo-strong">
            GitHub
          </Link>
        </nav>
      </div>
    </header>
  );
}
