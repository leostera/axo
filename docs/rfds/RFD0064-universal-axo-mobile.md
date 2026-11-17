# RFD0064 - Axo: one mobile app for iPhone and iPad

- Feature Name: `universal-axo-mobile`
- Status: In progress — product direction approved
- Author: leostera
- Start Date: 2026-11-17
- Document Type: Implementation design
- Related: [RFD0063](RFD0063-apple-distribution-and-apns.md)

## Summary

Rename the active Apple mobile product, modules and Bazel targets from AxoPhone to AxoMobile.
One universal iOS application supports iPhone and iPad. Share its workbench, authentication,
drafts, voice ownership and request ordering; adapt presentation to the current window's size
class rather than fork a tablet app. The installed icon continues to say Axo.

## Motivation and guide

The phone-only target cannot provide a native iPad workspace. A wide window should show the
chat sidebar beside its conversation, while a narrow window keeps the existing compact layers.
Selecting a chat or creating a draft on iPad keeps the sidebar visible. The account lives in the
sidebar; chat info opens separately. Rotation does not change the selected destination.

## Contract

- The canonical simulator and signed-device targets both include iPhone and iPad families.
  iPad supports all four orientations and does not require full screen.
- One outer WorkbenchView owns models, selection, drafts and dictation. Regular width uses
  NavigationSplitView; compact width uses the existing LayerStack. Layout is not command
  authority, and resizing never sends a message or answers a question.
- Keep current approval-before-Send and original-destination voice contracts. Watch
  connectivity remains guarded by platform support; an iPad is not a paired iPhone.
- Bazel is the only build. Regenerate the shared Xcode project; do not add an iPad project,
  duplicate app implementation or old product-label forwarding aliases.
- Renaming source/modules does not migrate app containers. The canonical bundle ID remains
  dev.leostera.axo. ExistingPhoneUpdate retains its explicit old identities and credential
  namespace. For explicitly approved owned-device testing, that manual target is also universal:
  update the existing iPhone in place and install the same development build on the iPad.
  This is not canonical-identifier migration; verify provisioning for each device before installation.
- Do not install the canonical app over the person's phone or reset its trusted signing key
  as part of tablet support. The already-installed 0.71 phone remains intact.

## Validation and rollout

Test shared mobile, watch and companion models after the module cutover. Inspect the built
universal bundle's device families and orientations. Drive the same app on fresh owned iPhone
and iPad simulators: sidebar/detail, rotation, chat selection, draft composition, global requests,
history, and compact navigation. Review screenshots. Physical installation and the canonical
credential migration remain separate checkpoints; no APNs or distribution-signing completion
is implied by simulator success.

## Alternatives and costs

Only enabling the tablet family is smaller but stretches the phone's layered UI across the
whole iPad. A separate tablet product duplicates behavior and contradicts the requested single
app. The adaptive shell adds presentation branches and therefore needs resize/rotation tests.
Source/module renaming changes contributor commands; update active consumers directly while
leaving historical RFDs and release records as historical records.

## Feedback corrections

App content is full-bleed: do not simulate the physical display’s corners or use private screen
geometry. Header actions belong to their pane, not a window-level overlay. A selected chat stays
listed and highlighted through section folding and limits, and its name remains visible in the
conversation header. Selection uses the full host/session key.

Legacy records can incorrectly report every platform as macos. Until platform reporting is
corrected independently, only a macos record with a reported Apple hardware identifier is
positively a Mac. Unknown/mixed collections say Hosts and never default to a laptop icon.

## Remaining work

Polish regular-width density, keyboard shortcuts, narrow/resizable iPad windows, sheets and
multiwindow voice ownership. Complete the independent credential bridge before canonical
phone installation. These are not claims of behavior already validated by the first slice.
