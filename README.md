# iTalk

Native SwiftUI assistant for iOS 26+ with an independent watchOS 26+ companion.
The implementation is in active development; production model access and paid
credits require operator configuration.

## Run

Open `iTalk.xcodeproj` in Xcode, select your development team, and run the iTalk
scheme on an iPhone. After adding source files, regenerate the project:

```sh
node scripts/generate-project.mjs
xcodebuild -downloadComponent MetalToolchain
swift test --package-path Packages/AssistantCore
npm --prefix server ci
npm --prefix server test
```

The generator preserves the project's selected development team. Set `ITALK_TEAM`
when generating to select a different team. The project currently uses Swift
6 and was built with Xcode 27. UI tests cover iOS 26.5 and selected iOS 27 flows. Watch targets
compile, but Watch execution has not been verified on a connected watch.

## Implemented

- Voice orb and text chat share the current in-memory conversation. A leading
  history drawer supports search and opening saved messages. Transparent native
  safe-area bars explicitly keep soft scroll edges on iOS 26 and 27. A single
  glass composer grows with text and scrolls at its line limit; long drafts also
  have an expanded editor. Outside taps dismiss the keyboard, text send retains
  typing focus, and input-mode changes preserve the draft. The sidebar uses native
  list rows on a solid navigation surface, with explicit empty/search states.
- An original Metal ceramic sphere moves between the voice scene and the header
  avatar. The identity uses an avatar above a glass name chip, without a dropdown.
  Content blur and shared geometry animate mode changes. Hold-to-talk adds a
  lower-screen gradient wash and cancellation color, beyond the input control.
  Motion, image previews, and editable dictation support light/dark appearance
  and Reduce Motion. Microphone level remains tied to real capture.
- On-device Mandarin SpeechAnalyzer transcription, local speech output, explicit
  audio interruption handling, and stale callback rejection. The audio tap factory
  is deliberately outside main-actor isolation; keep its regression probe.
- Local time/date, permission-gated HealthKit queries, reviewed calendar/reminder
  writes on iPhone, approved local memories, encrypted archive, export/deletion.
- An authenticated gateway with actual provider usage settlement, bounded spending
  reservations, duplicate turn protection, and verified StoreKit credit receipts.

Photos use the system picker, are resized to at most 1280 pixels, and re-encoded as
JPEG without the original metadata. At most three images can be sent after an
explicit per-turn confirmation. Image turns remain in RAM and are excluded from
the saved local history. The gateway does not persist prompt or image bodies;
provider retention depends on the configured provider. Conversation display is
bounded to 80 turns and 12 MB of encoded images.

## Gateway setup still required

Use `server/.env.example` as a private configuration template. Run the service with
Node 22+ using `node --env-file=.env src/main.mjs` from `server/`, behind HTTPS.
Enter that HTTPS URL and an account token in the app's settings, then review and
enable cloud processing. Provider credentials belong on the server.

Set the provider protocol, URL, model, API key, and commercial credit rates. Images
are disabled until `MODEL_SUPPORTS_IMAGES=true`; an image-capable account also
needs the `cloudImages` scope in `CLIENT_ACCOUNTS_JSON`. Text health processing
requires its separate `cloudHealth` scope and user grant. Confirm model compatibility
before enabling images. The client handles both Responses and compatible Chat
Completions through this gateway.

Real purchases require App Store Connect consumable products, the server product
mapping, Apple certificate roots, matching bundle/app identifiers, receipt
verification, and notification delivery. No live payment or paid model request
has been verified in this checkout. Public account provisioning, production
hosting, scheduled memory consolidation, and full Watch voice capture remain
unfinished.

The original research/design document is
`docs/voice-assistant-research-design.md`. UI references and deliberate differences
are recorded in `docs/conversation-ui.md`.
The follow-up navigation, keyboard, glass, and motion audit is in
`docs/ui-reference-audit.md`.
