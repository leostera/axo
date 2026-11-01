import ahrefsLogo from "./logos/ahrefs.svg";
import cloudflareLogo from "./logos/cloudflare.svg";
import githubLogo from "./logos/github.svg";
import huggingfaceLogo from "./logos/huggingface.svg";
import paypalLogo from "./logos/paypal.svg";
import stripeLogo from "./logos/stripe.svg";
import stravaLogo from "./logos/strava.svg";

/**
 * Remote MCP servers Axo knows, each its own tile and page under Settings › Apps. Each may be added
 * any number of times, under a name of the person's, for another account with the service. Only
 * servers reachable over streamable HTTP are here: ones that run on the person's computer (1Password's,
 * Twilio's) are not remote servers.
 */
export type KnownServer = {
  /** Its page: /settings/apps/mcp/<id>. */
  id: string;
  title: string;
  provider: string;
  category: string;
  url: string;
  logo: string;
  /** The logo is a full tile of its own, not a mark on white. */
  full?: boolean;
  description: string;
  /**
   * How it signs in: `self` registers Axo as a client by itself; `client` needs an OAuth app the
   * person registers with the provider (at `consoleUrl`); `none` needs no sign-in.
   */
  signIn: "self" | "client" | "none";
  consoleUrl?: string;
};

export const KNOWN_SERVERS: KnownServer[] = [
  {
    id: "github", title: "GitHub MCP", provider: "GitHub", category: "developer", url: "https://api.githubcopilot.com/mcp/", logo: githubLogo,
    description: "GitHub's own server: repositories, code, issues, pull requests, Actions and security alerts.",
    signIn: "client", consoleUrl: "https://github.com/settings/developers",
  },
  {
    id: "cloudflare", title: "Cloudflare", provider: "Cloudflare", category: "developer", url: "https://mcp.cloudflare.com/mcp", logo: cloudflareLogo,
    description: "All of Cloudflare's API through code: Workers, DNS, R2, D1, KV, zones and the account's other products.",
    signIn: "self",
  },
  {
    id: "cloudflare-docs", title: "Cloudflare Docs", provider: "Cloudflare", category: "developer", url: "https://docs.mcp.cloudflare.com/mcp", logo: cloudflareLogo,
    description: "Searches Cloudflare's documentation.", signIn: "none",
  },
  {
    id: "cloudflare-observability", title: "Cloudflare Observability", provider: "Cloudflare", category: "developer", url: "https://observability.mcp.cloudflare.com/mcp", logo: cloudflareLogo,
    description: "Your Workers' logs and analytics, to debug them.", signIn: "self",
  },
  {
    id: "cloudflare-browser", title: "Cloudflare Browser", provider: "Cloudflare", category: "developer", url: "https://browser.mcp.cloudflare.com/mcp", logo: cloudflareLogo,
    description: "Fetches web pages, turns them into Markdown and takes screenshots with Browser Rendering.", signIn: "self",
  },
  {
    id: "cloudflare-containers", title: "Cloudflare Containers", provider: "Cloudflare", category: "developer", url: "https://containers.mcp.cloudflare.com/mcp", logo: cloudflareLogo,
    description: "A sandbox to run code in, in a container.", signIn: "self",
  },
  {
    id: "cloudflare-radar", title: "Cloudflare Radar", provider: "Cloudflare", category: "developer", url: "https://radar.mcp.cloudflare.com/mcp", logo: cloudflareLogo,
    description: "Internet traffic trends, outages, attacks and domain rankings from Cloudflare Radar.", signIn: "self",
  },
  {
    id: "huggingface", title: "Hugging Face", provider: "Hugging Face", category: "developer", url: "https://huggingface.co/mcp", logo: huggingfaceLogo,
    description: "Searches the Hugging Face Hub's models, datasets, Spaces and papers, and runs Gradio apps.", signIn: "none",
  },
  {
    id: "ahrefs", title: "Ahrefs", provider: "Ahrefs", category: "marketing", url: "https://api.ahrefs.com/mcp/mcp", logo: ahrefsLogo,
    description: "Your Ahrefs data: backlinks, keywords, rankings, site metrics and competitors.", signIn: "self",
  },
  {
    id: "strava", title: "Strava", provider: "Strava", category: "health", url: "https://mcp.strava.com/mcp", logo: stravaLogo,
    description: "Your Strava activities, fitness trends, training load and goals.", signIn: "self",
  },
  {
    id: "stripe", title: "Stripe", provider: "Stripe", category: "finance", url: "https://mcp.stripe.com", logo: stripeLogo, full: true,
    description: "Your Stripe account: customers, payments, subscriptions, invoices and balance, and Stripe's docs.", signIn: "self",
  },
  {
    id: "paypal", title: "PayPal", provider: "PayPal", category: "finance", url: "https://mcp.paypal.com/mcp", logo: paypalLogo,
    description: "Your PayPal account: transactions, invoices, disputes and payment links.", signIn: "self",
  },
];

/** A URL as a server is matched by: its host and path, without a trailing slash. */
function endpoint(url: string): string {
  try {
    const parsed = new URL(url);
    return `${parsed.host}${parsed.pathname.replace(/\/+$/, "")}`.toLowerCase();
  } catch {
    return url;
  }
}

/** The known server a connection's URL is, if any. */
export function knownServerOf(url: string): KnownServer | undefined {
  const at = endpoint(url);
  return KNOWN_SERVERS.find((server) => endpoint(server.url) === at);
}
