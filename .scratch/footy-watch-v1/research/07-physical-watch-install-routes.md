# Physical Apple Watch Installation Routes

Status: research recommendation, not device proof  
Scope: Football Performance on an Apple Watch Series 8 running watchOS 26.5;
Xcode 26.6 cannot pair with the device and the watch does not show the
Developer Mode switch. Sources checked: Apple documentation, 2026-08-09.

## Decision

Use **TestFlight Internal Testing** for the next physical Series 8 recording
proof. It is the only prompt route that Apple documents as not depending on
Developer Mode or Xcode device pairing. Archive and upload the existing iOS
companion app, which embeds the Watch app. Invite an App Store Connect team
member, install from TestFlight on the paired iPhone, then confirm the Watch app
is present or install it from the iPhone's Watch app.

Do not spend time exporting an IPA for Apple Configurator, Ad Hoc, or
Development distribution while Developer Mode is unavailable. Apple explicitly
requires Developer Mode every time an IPA-based app runs on watchOS. Do not
treat the iPhone companion as a separate bypass: it only delivers the embedded
Watch app through the same signed distribution channel.

The current Watch target already declares
`WKRunsIndependentlyOfCompanionApp = true`, but it also has an embedded iOS
companion. That permits independent runtime behavior; it does not turn a local
development install into an App Store-style install. For this project, submit the
combined companion-and-Watch archive rather than attempting to hand-install the
Watch `.app`.

## Route comparison

| Route | Works with missing Developer Mode? | Prerequisites | Delay | Result for this case |
| --- | --- | --- | --- | --- |
| Xcode Build and Run | **No** | A Mac-paired watch/phone, Xcode platform support, signing, and Developer Mode enabled on the Watch | Immediate after pairing and build | Blocked. Apple says Developer Mode appears only after pairing starts or after a prior pairing. The missing switch is therefore consistent with the pairing failure. |
| Xcode/Apple Configurator local IPA | **No** | Archive/export, registered device, distribution profile, the paired iPhone attached to the Mac, and Developer Mode on the Watch | Immediate after export | Blocked. Apple calls out both Xcode and Apple Configurator installation for watchOS, and requires Developer Mode each time the IPA runs. |
| Ad Hoc distribution | **No** | Apple Developer Program, registered device, App ID, distribution certificate/profile, exported IPA, then Xcode or Apple Configurator installation | No App Review, but local-export/install work remains | Not a bypass. This is the signed IPA route above, so it still needs Developer Mode. |
| Development distribution | **No** | Apple Developer Program, registered device, development signing/profile, exported IPA, then Xcode or Apple Configurator installation | No App Review, but local-export/install work remains | Not a bypass. Apple documents Development as another registered-device export method. |
| TestFlight Internal Testing | **Yes** | Apple Developer Program, App Store Connect app record, archive upload, processed build, and up to 100 internal testers who are App Store Connect users | Upload processing only; Apple provides no fixed SLA and treats processing over 24 hours as a problem | **Recommended.** Apple states that Developer Mode does not affect TestFlight. Internal builds can be limited to the team and remain testable for 90 days. |
| TestFlight External Testing | **Yes** | The TestFlight requirements plus external group/test information and TestFlight App Review | Processing plus beta review. The first external build receives a full review; later builds may not | Valid fallback for people outside App Store Connect, but slower than internal testing. |
| App Store | **Yes** | App Store Connect metadata, selected build, App Review approval, and store availability | Review has no guarantee. Apple reports 90% of submissions review in under 24 hours on average; approved apps can take up to 24 hours to appear | A production route, not the fastest way to obtain focused device proof. |
| Install through the paired iPhone companion | **Depends on the channel** | The compatible iPhone app must first arrive through a named distribution route; for this situation, use TestFlight or the App Store. Keep the paired iPhone and Watch in range; use automatic install or the Watch app's **Available Apps** list | Follows the chosen route | A delivery step, not an independent distribution method. It bypasses Developer Mode only when the companion arrived through TestFlight or the App Store. |

## Why the local routes are blocked

Apple defines Developer Mode as the permission required for locally installed
apps. It applies to Build and Run in Xcode and to an `.ipa` installed with Apple
Configurator. The documentation further says the setting appears only when
pairing has begun or the device has previously been paired. Therefore, with both
the switch absent and the Xcode 26.6 pairing path broken, there is no supported
local-install workaround in this set of routes.

An Ad Hoc or Development archive changes signing and device registration. It does
not change the local-install security rule. Apple describes both as distribution
to registered devices, and its watchOS installation instructions require the
paired phone to be attached to the Mac.

## Recommended next action

1. Create an archive for the existing **FootballPerformance** iOS companion
   scheme. Its bundle includes the embedded Watch app.
2. Upload it using **TestFlight Internal Only** or ordinary TestFlight
   distribution restricted to an internal tester group.
3. Wait for the build status to become **Complete**. Apple states that a complete
   build is ready for testing, and recommends support escalation if processing
   exceeds 24 hours.
4. Add the tester to the internal group. The tester must be an App Store Connect
   user with an eligible role; the build expires after 90 days.
5. On the paired iPhone, accept the TestFlight invitation and install the app.
   Then verify that the Watch app installs automatically. If it does not, open
   the iPhone Watch app, find it under **Available Apps**, and select
   **Install**.
6. Run the actual Watch recording flow and capture physical-device evidence.

This path keeps the current device state intact. It does not require changing
Developer Mode, pairing Xcode, using Apple Configurator, or changing app code.

## Apple sources

- [Enabling Developer Mode on a device](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) — Developer Mode is required for Xcode and Apple Configurator local installation; it does not affect TestFlight or App Store installation; the switch appears after pairing starts or occurred previously.
- [Running your app on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) — Xcode physical-device build/run, signing, and platform-support requirements.
- [Distributing your app to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices) — registered-device prerequisites, paired-phone attachment for watchOS, Xcode/Configurator IPA install steps, and the every-run Developer Mode requirement.
- [Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases/) — archive requirement and Xcode distribution choices, including TestFlight Internal Only, Release Testing, Ad Hoc, and Development.
- [TestFlight Overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview) and [Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers) — watchOS support, 100 internal-testers limit, and 90-day test period.
- [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers) — TestFlight App Review requirements for external groups.
- [View builds and metadata](https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata/) — processed builds are ready for testing; processing over 24 hours may require support.
- [App Review](https://developer.apple.com/app-store/review/) and [publishing workflow](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/overview-of-publishing-your-app-on-the-app-store) — Apple’s current review statistic and up-to-24-hour storefront publication delay.
- [Download apps on your Apple Watch](https://support.apple.com/109023) — installation from the paired iPhone Watch app and the **Available Apps** list.
- [Setting up a watchOS project](https://developer.apple.com/documentation/watchos-apps/setting-up-a-watchos-project) — meaning of a companion app and independent Watch runtime.
