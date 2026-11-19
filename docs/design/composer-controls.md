# Composer controls

The message editor has one bottom toolbar on iPhone, iPad and web: Add → Host → Agent → Model → Thinking → Microphone → Send. Host, Agent, Model and Thinking are separate controls; the host is not repeated above the editor. Narrow displays compact labels or scroll the selector group while keeping voice and Send reachable. Preserve the mounted editor and target-bound text/attachments; selection never sends.

A live Session's host and agent are immutable. Their menus explicitly start a new chat, preserving the original Session's draft. Model and Thinking target the current Session and remain independent API mutations. Existing permission, availability and send-admission fences still apply.

The host publishes its actual `agent` kind as optional Session metadata. Absence means unknown, not Pi inferred from a model or an agent-presence flag. New drafts use discovered host-local agents only. Deploy the accepting API-worker metadata schema **before** any daemon starts emitting the new field; old strict workers would reject it. Clients accept older metadata without the field.

Follow-up before release: validate real agent labels on new daemons, new-chat model/thinking availability, 320pt layouts, Dynamic Type, menu clipping, keyboard navigation and draft retention across explicit new-Session choices. Do not claim installation completion while a physical device is locked or unreachable.
