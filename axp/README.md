# AXP: Agent Xchange Protocol

Specification: **https://axp.leostera.dev**

Coding agents run in isolation: a session lives in one process on one machine, and only the person at that terminal can see or steer it. Transcript files, such as [ATXF](https://atxf.leostera.dev), are fine for sharing a session once it is over, but they are a record of the past. **AXP** is for sessions that are still running: watching them from a phone, a browser or another computer, steering them safely over networks that drop, and keeping every copy of them in sync.

> Status: **v0.1 draft**. Expect breaking changes until v1.

## The problem

- **Controlling a remote session is hard.** A prompt sent from a phone needs a path to the machine running the agent, and an answer to "did it run?" when the connection drops mid-request. Resending can run it twice; not resending can lose it.
- **Replicating a live session is hard.** Every viewer needs the same log in the same order as it is written, resumable after any disconnect, and safe from a relay that drops or alters records.
- **Knowing what runs where is hard.** Which machines exist, which sessions each runs, which are working and which wait for a person.
- **Machines cannot reach each other.** Laptops sit behind NAT and phones change networks, so something has to relay, without being able to forge what an agent said.
- **Letting a device in is hard to do safely.** Pairing a phone should take a short code, not a password or a secret sent on every connection.
- **Every tool solves this alone,** with its own wire format tied to one agent and one product.

AXP specifies the answers once, with a small core and extensions, so that any host, relay and client can work together, whatever agent the host runs.

## Design in one screen

- **Three roles.** A **host** runs agent Sessions and is the only writer of each Session's log. A **hub** connects hosts and clients that cannot reach each other and keeps a replica of every log. A **client** shows Sessions and sends commands. A client can talk to a host directly or through a hub; the messages are the same.
- **JSON-RPC 2.0** over a Unix socket (one message per line) or a WebSocket (one message per frame). Messages larger than a frame travel in fragments, by priority, so a large upload never holds back a reply.
- **One handshake.** `axp.hello` agrees on the version, the extensions and the limits.
- **Devices, not passwords.** A new device joins an account with a short, single-use code from a device already in it, and from then on proves itself by signing a challenge with an Ed25519 key it never exports.
- **Logs are ATXF transcripts** with integrity. A copy describes what it holds with the values an ATXF seal would carry, `{count, chain}`, and receives exactly what it is missing. Every reader verifies every record's hash and the chain, so a hub cannot forge, reorder or drop records.
- **Commands run at most once.** A command carries a `commandId`; the host never runs one twice, so a client can always resend after an unknown outcome. The records a command produces carry its id, covered by their hashes.
- **Ephemeral state** (the reply being written, a tool's progress) travels in slots that hold only their latest value and are never stored.
- **Extensions** for everything else: Sessions and workspaces, Pi, terminals, tools at the hub, public shares, planned restarts, local control.

```jsonl
{"jsonrpc":"2.0","id":6,"method":"axp.log.open","params":{"hostId":"8d9c4a1b-…","sessionId":"5b7d9f1a-…","have":{"count":5,"chain":"sha256:…"}}}
{"jsonrpc":"2.0","method":"pi.prompt","id":8,"params":{"hostId":"8d9c4a1b-…","sessionId":"5b7d9f1a-…","commandId":"cmd_q8ZpL2vR7sKx","text":"Add a section on pairing."}}
{"jsonrpc":"2.0","id":8,"result":{"receipt":"accepted"}}
```

## Contents

| Path | What |
| --- | --- |
| [`SPEC.md`](SPEC.md) | The core: roles, transports, connections, trust and pairing, hosts and Sessions, logs and replication, routed calls and commands, ephemeral state, errors, limits |
| [`extensions/`](extensions) | The extension registry and one document per extension |
| [`schema/v0.1/axp.schema.json`](schema/v0.1/axp.schema.json) | JSON Schema (draft 2020-12) for the core's methods and notifications |
| [`schema/v0.1/ext/`](schema/v0.1/ext) | One JSON Schema per extension |
| [`examples/`](examples) | Whole exchanges, one message per line, with real hashes, chains and signatures |
| [`scripts/examples.ts`](scripts/examples.ts) | Writes the examples |
| [`tests/`](tests) | Checks that the documents, schemas and examples agree |

## Check it

From the repository root:

```sh
bazel test //axp/...
```

Or with Node 22.18 or later, after `pnpm install`:

```sh
cd axp
node --test tests/          # schemas, examples, hashes, signatures, documents
node scripts/examples.ts    # rewrite the examples
```

## Roadmap

- Reference implementations in TypeScript and Rust that agree byte for byte, and a Swift client, with a reference hub, host and client.
- Conformance fixtures for each method's failure cases.
- Feynman models of replication, delivery, commands, fragments and pairing.
- Signed seals, from the device keys pairing already creates.
