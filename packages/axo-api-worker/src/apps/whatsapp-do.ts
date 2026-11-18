import { DurableObject } from "cloudflare:workers";
import { whatsapp, WhatsAppDevice, type LinkedDevice, type LinkedOutcome, type LinkStart, type LinkState } from "@axo/apps";
import { Keyring, type KeyEnvironment } from "../auth/keys";

/**
 * One linked WhatsApp device of an account's (RFD0016, Linked devices), named
 * `<accountId>:<device>`; only the account's Durable Object, which made it, reaches it. It holds
 * the device's connection to WhatsApp and its cache, and runs `apps.whatsapp`'s tools against
 * that cache. An alarm wakes it every minute while it is linked, so it connects again after a
 * deploy or an eviction; WhatsApp keeps what arrived meanwhile and sends it then.
 */
export class AxoWhatsAppDO extends DurableObject<Env> implements LinkedDevice {
  private readonly device: WhatsAppDevice;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
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

  startLink(start: LinkStart): Promise<LinkState> {
    return this.device.startLink(start);
  }

  async linkState(): Promise<LinkState> {
    return this.device.linkState();
  }

  unlink(): Promise<void> {
    return this.device.unlink();
  }

  run(tool: string, input: Record<string, unknown>): Promise<LinkedOutcome> {
    return this.device.run(whatsapp.tools, tool, input).catch((error: unknown) => ({ error: error instanceof Error ? error.message.slice(0, 300) : "WhatsApp failed" }));
  }

  override async alarm(): Promise<void> {
    await this.device.alarm();
  }
}
