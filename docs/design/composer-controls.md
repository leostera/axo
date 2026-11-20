# Composer controls

The message editor has one bottom toolbar on iPhone, iPad and web. Add sits alone on the left. On the right: Host → Agent → Model → Thinking → Microphone → Send. The selector group is fixed. Narrow displays shorten the text and use icons for draft destinations and thinking. Preserve the mounted editor and target-bound text/attachments; selection never sends.

An existing Session shows Host and Agent as noninteractive badges, with the host's machine icon. On compact iPhone layouts these badges sit at the leading edge below the conversation title; on regular iPad layouts they remain in the toolbar. Each item in the new-chat host menu uses the same host icon policy. Only a new chat has Host and Agent menus. Model and Thinking target the selected Session and remain independent API mutations. Existing permission, availability and send-admission fences still apply.

The host publishes its actual `agent` kind as optional Session metadata. Absence means unknown, not Pi inferred from a model or an agent-presence flag. New drafts use discovered host-local agents only. Deploy the accepting API-worker metadata schema **before** any daemon starts emitting the new field; old strict workers would reject it. Clients accept older metadata without the field.

Follow-up before release: validate real agent labels on new daemons, new-chat model/thinking availability, 320pt layouts, Dynamic Type, menu clipping, keyboard navigation and draft retention across explicit new-Session choices. Do not claim installation completion while a physical device is locked or unreachable.
