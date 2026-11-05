# axo-signin

Loopback sign-in (RFD0016). Some services only send a sign-in back to `http://localhost`, so it has to end on the person's Mac: `sign_in` listens on one of the service's registered redirect ports, opens the sign-in page in the browser, and waits (at most `MAX_TIMEOUT`) for the browser to return with the code.

It knows nothing about any one service. The caller (the Worker, through the relay) builds the sign-in URL and keeps the PKCE verifier, so the one-time code returned here is useless without it. Nothing is written to disk and nothing secret is logged.

Used by `axo-relay`'s `signin` module.

## Build and test

```sh
bazel build //crates/axo-signin
bazel test //crates/axo-signin:axo_signin_tests
```
