# Switching the host of a chat

Use the same acceptance scenario on web, iOS, and native Mac. Use a disposable Pi session and two paired hosts. A new chat has no history: switching its destination keeps the draft and creates nothing. The cases below cover an existing chat.

1. On A, start a Pi chat with a recognizable message. On B, create a folder with the same path but different contents. Enter (but do not send) another message on A.
2. Select B. The picker names B and asks whether to fork. It explains that history is copied but project files are not. Cancel: selection, draft and history on A must not change. No session is created on B.
3. Confirm a fork. Only after B confirms, open a different session ID owned by B. Its working directory is B's canonical folder. A remains open and its transcript is unchanged. An in-progress reply on A is not interrupted or continued on B.
4. Inspect B's transcript before sending a prompt: at the confirmed snapshot boundary it has one new Pi custom message, `display: false`, with actual source and destination hosts and folders. The note distinguishes historical tool output from observations of B. No visible notice bubble, assistant turn, tool execution, pending approval or queued prompt is produced by the fork itself.
5. Ask B which folder it is in. A fresh filesystem observation must be of B, not A. Additional turns on either host must not appear in the other's child/parent history.
6. Repeat with the source folder absent on B: no silent fallback to home and no partial child. Choose an existing folder on B, reconfirm, and check that the note names this folder. Cancel or submit a missing folder: keep the source selected.
7. Disconnect B before confirmation, try an unsupported agent, and try a destination whose copy is behind. None may report a successful fork from incomplete history. If the reply is lost after creation, a retry of the same operation must not create another child.

A mocked picker test alone does not establish platform support: verify the destination RPC, actual child transcript, and client navigation separately.
