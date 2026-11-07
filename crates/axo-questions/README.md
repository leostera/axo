# axo-questions

The questions extension of axod (RFD0029, RFD0034): what agents on this Mac ask the person, and
waiting for the answer. `axo.elicitation.request`, `.list`, and `.resolve` (Axo.app alone, by code
signature); answers from other devices come through the relay.

- The first answer taken wins; a question that nobody answers in time, or whose asker gives up
  (its request is cancelled), ends as `cancel`, and every client is told.
- A form's values are sealed to this Mac's input key, for that request and address; they open
  here only, and are wiped when dropped.
- At most `MAX_PENDING` wait at once.

The rest of axod is a `QuestionsHost` (open Sessions, events, the input key), passed to each call.
The computer-use gate and forms ask through `Questions::ask` and `ask_with`.

Tests: `bazel test //crates/axo-questions/...`; end to end in `//crates/axod:conformance_elicitations`
and `conformance_relay`; models in `specs/elicitations` and `specs/cancellation/questions.ts`.
