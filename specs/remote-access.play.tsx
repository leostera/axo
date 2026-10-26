import { definePlayground, Terminal } from "@feynman/play";
import spec from "./remote-access.ts";

const { Person, Manager, Axod } = spec.handles;

export default definePlayground(spec, (play) => {
  // While the relay is closed, say how many pairing codes are waiting to be typed into a Mac.
  play.group("Axo relay", {
    status: ({ member, clock }) => {
      const pairings = Object.values(member(Manager)?.state.pairings ?? {});
      const waiting = pairings.filter((p) => p.consumed === null && p.expires > clock).length;
      return waiting === 1 ? "1 code waiting" : waiting > 1 ? `${waiting} codes waiting` : "no codes waiting";
    },
  });

  // A terminal beside a person while they have a Mac open.
  play.actor(Person, {
    panel: ({ state, world, live, act }) => {
      const host = Object.keys(state.watching)[0];
      if (!host) return null;
      const lines = state.asked.flatMap((request) => {
        if (!state.commands[request]) return [];
        const typed = `$ ${state.commands[request]}`;
        if (state.outputs.includes(request)) return [typed, "ok"];
        return state.timedOut.includes(request) ? [typed, "(no answer)"] : [typed];
      });
      return (
        <Terminal
          title={world.all(Axod).find((a) => a.id === host)?.label ?? host}
          lines={lines}
          commands={["whoami", "uptime", "ls"]}
          onRun={live ? (command) => act("run", { host, command }) : undefined}
        />
      );
    },
  });
});
