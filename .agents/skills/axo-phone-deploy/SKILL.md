---
name: axo-phone-deploy
description: Build and install the Axo iPhone app on Leo's phone. Use after any change to apple/AxoPhone (or anything it builds from) once it is validated and committed.
---

# Axo phone deploy

**Redeploy the phone app after every validated AxoPhone change.** Tests passing in the
simulator are not delivery; Leo tries changes on his phone.

```bash
scripts/build-phone.sh --install
```

It reserves the next phone build number, builds `//apple/AxoPhone:AxoPhoneDevice` for arm64,
checks the stamped `CFBundleVersion`, installs on the phone (`AXO_PHONE_DEVICE`, default Leo's
iPhone) and relaunches Axo. "the phone is locked" means it installed but could not launch; say so.

- Check the phone is reachable first if the install fails: `xcrun devicectl list devices`
  (it should be `available (paired)`).
- Report the build number in your reply, so Leo knows which build he is holding.
- Deploy what is committed and validated; if the tree has others' uncommitted phone changes, they
  ship too. Mention it.
