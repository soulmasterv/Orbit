# JARVIS in Orbit

## Delivery and scope

Home → JARVIS embeds the live HTTPS site at `https://jarvis.labbing.space/` in WKWebView (iOS 17+). The website retains its Start voice, Stop, Sign out and Memory UI. Orbit adds microphone capture status, an always-available Stop control, Memory shortcut and Reload. No provider connection, password, API key, audio recording or transcript is stored by the integration. No cellular-call audio or SIM calling is involved.

Public DNS and the password login page were checked; the owner signed in and the signed-in controls were inspected in a desktop browser. That does not establish physical iPhone voice compatibility. The supplied handoff was the source of the cookie/CSRF/WebSocket/audio contract; the backend was not changed or independently exercised with private credentials.

## Frontend update required on Ubuntu

The supplied frontend had two relevant gaps: asynchronous microphone/worklet setup could finish after Stop and interfere with a replacement session, and page backgrounding did not perform full cleanup. A native audio bridge is not justified by those gaps; the supplied frontend patch fixes them while retaining the existing audio and authenticated WebSocket protocol.

The app requires `window.orbitJarvis.version === 1` before granting microphone capture. **Until the updated frontend is deployed, login can load but voice remains disabled with an explanatory notice.** The deployment is separate from the IPA and has not been performed by the app agent.

On Ubuntu, back up the existing JARVIS `public` directory, then copy the five files from `backend/jarvis/public/` into the matching existing JARVIS frontend directory:

- `app.js`: generation-scoped voice sessions; synchronous disposal of tracks/socket/queued playback/context; visibility/pagehide/offline/interruption cleanup; narrow versioned lifecycle hook.
- `memory.js`: preserve explicit user Save and confirmation dialogs; clear auth-expired message; notify voice UI after successful memory changes.
- `index.html`: supplied existing Memory panel and voice/login controls.
- `capture.js`: unchanged supplied 16 kHz PCM16 streaming AudioWorklet.
- `style.css`: unchanged supplied styling.

Use the current JARVIS deployment method to serve these files. No origin, tunnel, authentication, CSRF, cookie, school knowledge or Gemini settings should change. Do not substitute a new backend or guessed directory. After deployment, reload the website and Orbit's JARVIS screen. Confirm Memory appears after sign-in, and the “frontend update” notice disappears. Roll back the five frontend files if necessary; older frontend remains intentionally unable to start voice in Orbit.

## Authentication and privacy

The persistent `WKWebsiteDataStore.default()` retains the server's Secure HttpOnly session cookies and sends same-origin requests/WS naturally. The app never reads the cookie or CSRF token and never copies the password from the login form. No bearer token or Students API key is attached to JARVIS. Login/logout remain the site's exact-origin CSRF-protected operations. Logout is reported successful only after the server acknowledges it or reports an expired session. Stop does not sign out.

Only the exact HTTPS JARVIS origin on default/443 port may be embedded or request microphone capture. Camera and camera+microphone requests are denied. Permission needs a trusted Start click, compatible frontend, authenticated state and foreground screen; pending permission results are invalidated by Stop/background/navigation. The OS usage string is in project.yml. No ATS exception, certificate override or background audio mode is added.

The observed public page uses its own password login, with no Cloudflare Access redirect. Consequently **no external authentication hosts are pre-approved**. An unexpected Access/Google redirect is blocked and explained. User-tapped unrelated HTTP(S) links open externally; automatic redirects do not. If Access is added later, verify that exact flow and WKWebView compatibility before adding any auth destination. Do not assume Safari's cookies or the desktop browser's login transfer into Orbit.

The web lifecycle hook only exposes version, stop and a snapshot containing authenticated/phase/memoryAvailable flags. Native code evaluates fixed, origin-checked scripts only; no general-purpose JS or native API bridge is available to the page. Native Stop additionally terminates WK microphone capture and pauses playback; backgrounding suspends playback, and leaving destroys the page. Foregrounding never resumes recording or automatically reconnects.

## Audio and failure behavior

Start remains an actual web button user gesture so AudioContext activation is preserved. Capture uses the existing worklet's actual-rate resampling to 16 kHz PCM16, `wss://jarvis.labbing.space/voice`, cookie authentication and the existing first `{csrf}` message. Replies remain 24 kHz PCM playback. No mutation or voice connection automatically retries.

Mic denial, offline state, a failed page load, socket refusal/session limits, playback queue pressure, interrupted AudioContext, disconnected microphone and changed audio routes show guidance and require another explicit Start. The native audio session uses playAndRecord/voiceChat with Bluetooth headset support and the speaker default. Actual routing, permission transitions and echo behavior require the device tests below.

Memory proposals remain unsaved drafts. Existing create/edit/delete behavior stays in the web UI. JavaScript deletion confirmations are presented as native confirmation alerts. Adding/editing/deleting saved memory ends the current conversation; the next explicit Start uses the current memory list.

## Build, signing and installation

1. Push these files to the existing repository main branch. The existing Build ServerControl IPA GitHub Actions workflow runs the backend adapter tests, JARVIS Node lifecycle tests, XcodeGen, unsigned arm64 iPhone Release build and complete iOS simulator tests, then packages `ServerControl.ipa`.
2. Download `ServerControl-IPA` from that successful run's Artifacts and extract the ZIP on Windows.
3. Transfer `ServerControl.ipa` to the iPhone, open SideStore and use its normal Add/Install IPA flow to sign and install over the current Orbit app. Keep the same Apple account/signing identity and app bundle identifier to preserve Keychain access. Product filename and bundle ID remain ServerControl/com.servercontrol.app; the display name stays Orbit.
4. Unlock Orbit, open Home → JARVIS, sign in to JARVIS inside the app, and tap Start voice to request microphone permission. Existing desktop browser sign-in is not transferred.

No Mac, provisioning profile, signing key or server secret is required in GitHub. SideStore performs personal signing on the user's device. If building on a Mac instead: generate with `xcodegen generate`, open ServerControl.xcodeproj, select the existing ServerControl scheme; the workflow contains the exact unsigned build/test commands. This change does not alter the existing signing setup.

## Verification boundaries

Automated checks use fake audio/socket objects and test lifecycle races without recording or contacting Gemini. iOS unit tests cover strict origin/port matching, incompatible frontend denial, foreground/auth/tap requirements, one-use gestures, invalidation of pending permission after Stop/background/navigation, persistent WebKit storage and Info.plist security settings. CI compilation and simulator results must be reported from the actual run, not inferred from this document.

Still required on the owner's physical iPhone:

- Login and relaunch cookie persistence; sign-out success and offline sign-out failure.
- First microphone prompt; deny and re-enable from Settings; speaking and hearing replies.
- Verify Stop removes the iOS microphone indicator, including during pending permission/startup.
- Leave screen, lock phone/background, interruption and headphone/Bluetooth connect/disconnect: capture and playback stop, and returning never resumes a session.
- Authenticated WebSocket upgrade, login expiry, server restart, shared-session refusal and duration limit.
- Network change/loss: no silent redial, no replay of old audio.
- Memory list/create/edit/delete, native deletion confirmation and unsaved spoken proposals.
- School knowledge and reviewed memory remain unchanged on the server.

Do not call voice reliability verified until these checks pass on the actual iPhone/iOS version. If a device-specific WKWebView limitation emerges, record the exact failed stage before considering a native PCM bridge.
