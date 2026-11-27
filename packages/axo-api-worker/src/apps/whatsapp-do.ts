import { DurableObject } from "cloudflare:workers";
import { whatsapp, WhatsAppDevice, type LinkedDevice, type LinkedOutcome, type LinkStart, type LinkState } from "@axo/apps";
import { Keyring, type KeyEnvironment } from "../auth/keys";

// Emergency compute pause. Keep the namespace and pairing state; do not unlink devices.
const WHATSAPP_PAUSED = true;
const PAUSED = "Axo's WhatsApp integration is temporarily paused.";

/**
 * One linked WhatsApp device of an account's (RFD0016, Linked devices), named
 * `<accountId>:<device>`; only the account's Durable Object, which made it, reaches it. It holds
 * the device's connection to WhatsApp and its cache, and runs `apps.whatsapp`'s tools against
 * that cache. An alarm wakes it every minute while it is linked, so it connects again after a
 * deploy or an eviction; WhatsApp keeps what arrived meanwhile and sends it then.
 */
export class AxoWhatsAppDO extends DurableObject<Env> implements LinkedDevice {
  private readonly device: WhatsAppDevice | null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    if (WHATSAPP_PAUSED) {
      this.device = null;
      return;
    }
    const purpose = `apps-whatsapp-device\0${ctx.id.toString()}`;
    const keys = () => {
      const parsed = Keyring.parse(env as KeyEnvironment);
      if (!parsed) throw new Error("The Worker's keys are not configured");
      return parsed;
    };
    this.device = new WhatsAppDevice({
      sql: ctx.storage.sql,
      seal: (plain) => keys().seal(purpose, plain),
      unseal: async (sealed) => {
        const plain = await keys().unseal(purpose, sealed, 1 << 20);
        return typeof plain === "string" ? plain : null;
      },
      transaction: (work) => ctx.storage.transactionSync(work),
      setAlarm: (at) => ctx.storage.setAlarm(at),
      deleteAlarm: () => ctx.storage.deleteAlarm(),
    });
  }

  async startLink(start: LinkStart): Promise<LinkState> {
    return this.device ? this.device.startLink(start) : { state: "failed", error: PAUSED };
  }

  async linkState(): Promise<LinkState> {
    return this.device ? this.device.linkState() : { state: "failed", error: PAUSED };
  }

  async unlink(): Promise<void> {
    if (!this.device) throw new Error(PAUSED);
    await this.device.unlink();
  }

  async run(tool: string, input: Record<string, unknown>): Promise<LinkedOutcome> {
    if (!this.device) return { error: PAUSED };
    try {
      // The first tool call after resuming restarts the watchdog for an existing pairing.
      if (this.device.status() === "linked" && await this.ctx.storage.getAlarm() === null) {
        await this.device.alarm();
      }
      return await this.device.run(whatsapp.tools, tool, input);
    } catch (error) {
      return { error: error instanceof Error ? error.message.slice(0, 300) : "WhatsApp failed" };
    }
  }

  override async alarm(): Promise<void> {
    // An already scheduled alarm may fire once during the pause. Do not reschedule it.
    await this.device?.alarm();
  }
}
