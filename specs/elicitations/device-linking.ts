import { atMost, defineActor, defineMessage, defineProperty, defineRule, defineScenario, defineSpec, defineZone } from "@leostera/feynman";

// RFD0078: the relay sees proofs and ciphertext, never the physical QR capability.
const Claim = defineMessage("LinkPhone", { key: String, proof: String }, { over: "relay" });
const Grant = defineMessage("LinkDevice", { key: String, signer: String, domain: String }, { over: "relay" });
const physicalCode = defineRule("physicalCode", { description: "Only the scanner possesses the private one-use QR capability." });
const management = defineRule("management", { description: "An answer permission or login never delegates device management; only a currently linked hub does." });
const domains = defineRule("domains", { description: "An answer signature cannot be used as a device-linking grant." });
const macZone = defineZone({ name: "Trusted Mac" });
const relayZone = defineZone({ name: "Relay", place: { column: 1 } });
const phoneZone = defineZone({ name: "Phone", place: { column: 2 } });

export const Mac = defineActor({
  name: "Mac", zone: macZone, singleton: true,
  initialState: () => ({ code: false, used: false, expired: false, manager: false, revoked: false, linked: [] as string[], invalidGrant: false, unscannedHub: false }),
  actions: {
    showCode: { with: [atMost(1)], label: "Show private code in signed Axo.app", run(s) { s.code = true; } },
    expire: { with: [atMost(1)], label: "Expire code", run(s) { s.expired = true; } },
    revoke: { with: [atMost(1)], label: "Revoke hub", run(s) { s.revoked = true; s.manager = false; } },
  },
  transitions: {
    bootstrap: { on: Claim, description: "One active physical code binds exactly the scanning phone key.", run(s, m) {
      if (!s.code || s.expired || s.used) return;
      if (physicalCode.on && (m.proof !== "camera-capability" || m.key !== "phone-key")) return;
      s.used = true;
      s.manager = !s.revoked;
      s.unscannedHub = m.proof !== "camera-capability" || m.key !== "phone-key";
    } },
    grant: { on: Grant, description: "Only a current hub's linking signature grants an independent responder.", run(s, m) {
      const authorized = s.manager && !s.revoked && m.signer === "phone-key";
      if (management.on && !authorized) return;
      if (domains.on && m.domain !== "link-device") return;
      s.invalidGrant ||= !authorized || m.domain !== "link-device";
      if (!s.linked.includes(m.key)) s.linked.push(m.key);
    } },
  },
});

export const Relay = defineActor({
  name: "Relay", zone: relayZone, singleton: true, initialState: () => ({}),
  actions: {
    forgeCode: { with: [atMost(1)], label: "Forge bootstrap from account login", sends: [Claim], run(_s, _i, ctx) {
      ctx.send(ctx.the(Mac), Claim, { key: "relay-key", proof: "account-session" });
    } },
    forgeGrant: { with: [atMost(1)], label: "Forge device-management authority", sends: [Grant], run(_s, _i, ctx) {
      ctx.send(ctx.the(Mac), Grant, { key: "relay-client", signer: "answer-only-key", domain: "link-device" });
    } },
    replayAnswer: { with: [atMost(1)], label: "Replay a Yes as a device grant", sends: [Grant], run(_s, _i, ctx) {
      ctx.send(ctx.the(Mac), Grant, { key: "relay-client", signer: "phone-key", domain: "answer" });
    } },
  },
  transitions: {
    claim: { on: Claim, description: "Forward a camera proof, without learning its capability.", sends: [Claim], run: (_s, m, ctx) => ctx.send(ctx.the(Mac), Claim, m) },
    grant: { on: Grant, description: "Forward a scoped signed grant.", sends: [Grant], run: (_s, m, ctx) => ctx.send(ctx.the(Mac), Grant, m) },
  },
});

export const Phone = defineActor({
  name: "Phone", zone: phoneZone, singleton: true, initialState: () => ({ signedIn: false }),
  actions: {
    signIn: { with: [atMost(1)], label: "Sign in", run(s) { s.signedIn = true; } },
    scan: { with: [atMost(1)], label: "Scan the physical Mac code", sends: [Claim], run(_s, _i, ctx) {
      ctx.send(ctx.the(Relay), Claim, { key: "phone-key", proof: "camera-capability" });
    } },
    allow: { with: [atMost(1)], label: "Allow the scanned iPad", sends: [Grant], run(_s, _i, ctx) {
      ctx.send(ctx.the(Relay), Grant, { key: "ipad-key", signer: "phone-key", domain: "link-device" });
    } },
  },
});

const happy = defineScenario("Phone becomes the hub", {
  run(s) {
    s.act(s.the(Phone), "signIn");
    s.act(s.the(Mac), "showCode");
    s.act(s.the(Phone), "scan"); s.settle();
    s.act(s.the(Phone), "allow"); s.settle();
  },
});

export default defineSpec({
  name: "Physical device linking", description: "Account login cannot manufacture a pairing grant; one camera bootstrap gives a narrowly delegated hub capability.",
  actors: [Mac, Relay, Phone], scenarios: [happy],
  properties: [
    defineProperty("noHubFromLogin", { always: w => !w.the(Mac).state.unscannedHub, needs: [physicalCode] }),
    defineProperty("onlyCurrentManagementGrants", { always: w => !w.the(Mac).state.invalidGrant, needs: [management, domains] }),
    defineProperty("noRelayDevice", { always: w => w.the(Mac).state.linked.every(key => key === "ipad-key"), needs: [management, domains] }),
  ],
});
