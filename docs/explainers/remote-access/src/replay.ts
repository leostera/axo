// `perform` is the one way a person changes the simulation: it runs the command and records it,
// with the time it happened at, in `sim.inputs`. `replay` runs a recording back from a preset and
// rebuilds the time-travel history on the way, so a shared link can be rewound like a live run.
//
// This relies on the simulator being deterministic: no randomness and no wall-clock reads.

import type { Command, Input } from "./commands";
import {
  addClient,
  addMac,
  addPerson,
  advance,
  clientActions,
  macActions,
  nextEventAt,
  setFlag,
  skip,
  type Ms,
  type Sim,
} from "./sim";

/** How many past states time travel keeps. */
export const HISTORY = 300;

function run(sim: Sim, c: Command): Sim {
  switch (c.t) {
    case "addPerson": return addPerson(sim, c.name);
    case "addClient": return addClient(sim, c.kind, c.owner, c.label);
    case "addMac": return addMac(sim, c.name);
    case "setFlag": return setFlag(sim, c.flag, c.value);
    case "signIn": return clientActions.signIn(sim, c.client, c.person);
    case "signOut": return clientActions.signOut(sim, c.client);
    case "createCode": return clientActions.createCode(sim, c.client);
    case "listHosts": return clientActions.listHosts(sim, c.client);
    case "open": return clientActions.open(sim, c.client, c.hostId);
    case "leave": return clientActions.leave(sim, c.client);
    case "revoke": return clientActions.revoke(sim, c.client, c.hostId);
    case "clientType": return clientActions.type(sim, c.client, c.text);
    case "link": return macActions.link(sim, c.mac, c.code);
    case "setNetwork": return macActions.setNetwork(sim, c.mac, c.online);
    case "restart": return macActions.restart(sim, c.mac);
    case "retry": return macActions.retry(sim, c.mac);
    case "unlink": return macActions.unlink(sim, c.mac);
    case "macType": return macActions.type(sim, c.mac, c.text);
    case "skip": return skip(sim, c.by);
  }
}

/** Commands only make sense for things that exist; a stale link must fail, not half-apply. */
function requireReferences(sim: Sim, c: Command) {
  const missing = (kind: string, id: string) => new Error(`${c.t}: no such ${kind} "${id}"`);
  if ("client" in c && !sim.clients.some((x) => x.id === c.client)) throw missing("client", c.client);
  if ("mac" in c && !sim.macs.some((x) => x.id === c.mac)) throw missing("mac", c.mac);
  if ("person" in c && !sim.people.some((x) => x.id === c.person)) throw missing("person", c.person);
  if (c.t === "addClient" && c.owner !== "" && !sim.people.some((x) => x.id === c.owner)) throw missing("person", c.owner);
}

export function perform(sim: Sim, command: Command): Sim {
  requireReferences(sim, command);
  const input: Input = { at: sim.now, command };
  return { ...run(sim, command), inputs: [...sim.inputs, input] };
}

export type Replayed = { sim: Sim; history: Sim[] };

/**
 * Runs `inputs` on `start` and ends at simulated time `until`. `history` has the state before every
 * event and every input, like a live run's. Throws if an input doesn't apply (a stale or edited link).
 */
export function replay(start: Sim, inputs: readonly Input[], until: Ms): Replayed {
  let sim = start;
  const history: Sim[] = [];

  const runTo = (to: Ms) => {
    for (let at = nextEventAt(sim); at !== null && at <= to; at = nextEventAt(sim)) {
      history.push(sim);
      sim = advance(sim, at, 1).sim;
    }
    if (sim.now < to) sim = advance(sim, to).sim;
  };

  for (const input of inputs) {
    runTo(input.at);
    history.push(sim);
    sim = perform(sim, input.command);
  }
  runTo(until);
  return { sim, history: history.slice(-HISTORY) };
}
