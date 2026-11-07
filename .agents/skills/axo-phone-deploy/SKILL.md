---
name: axo-phone-deploy
description: Build and install the Axo iPhone app on Leo's phone. Use after any change to apple/AxoPhone (or anything it builds from) once it is validated and committed.
---

# Axo phone deploy

**Redeploy the phone app after every validated AxoPhone change.** Tests passing in the
simulator are not delivery; Leo tries changes on his phone. When the change also touches the
Mac app, axod or anything else shipped, publish that too, following
[packaging](../axo-macos-packaging/SKILL.md)'s "Always publish and deploy safe changes".

Every `bazel build` builds `//apple/AxoPhone:AxoPhoneDevice` for arm64 when this Mac has the
phone's provisioning profile, and installs and relaunches it on the phone when
`config.local.json` (ignored by git) says so:

```json
{ "phone": { "device": "00008130-00041CE83EFA001C", "install": true } }
```

```bash
bazel build //...
cat bazel-bin/report.txt
```

The `phone install:` line of the report says what happened: installed and opened, installed but
"the phone is locked" (say so), or why it was not installed. The build never fails over the phone.

- The build number is `builds.phone` in `config.json`. Bump it in a commit when a build should be
  told apart from the last one Leo has.
- Check the phone is reachable first if the install fails: `xcrun devicectl list devices`
  (it should be `available (paired)`).
- Report the build number in your reply, so Leo knows which build he is holding.
- Deploy what is committed and validated; if the tree has others' uncommitted phone changes, they
  ship too. Mention it.
