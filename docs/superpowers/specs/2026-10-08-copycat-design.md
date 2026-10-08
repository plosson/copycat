# Copycat — design

Date: 2026-10-08
Status: draft, awaiting review

## Purpose

Browsers cannot put a real animated GIF, a video or any other file on the
system clipboard. The web Clipboard API only guarantees `text/plain`,
`text/html` and `image/png`; a GIF becomes a single still frame, and an MP4
cannot be copied at all. A Chrome extension does not help: it uses the same
API.

Copycat is a small macOS menu bar app that fills that gap. A web page asks
Copycat to copy a file by URL; Copycat downloads it and puts the real file on
the macOS clipboard. The user can then paste it into any app — Messages,
Slack, WhatsApp, Discord, Mail — and a GIF stays animated, a video arrives as
a playable file.

Copycat knows nothing about any particular website. Any site can use it
through a small JavaScript file, once the user has allowed that site.

### Success criteria

1. With Copycat running, pressing a Copy button on a web page in Chrome, then
   pasting into Messages, Slack and WhatsApp desktop, gives an animated GIF
   or a playable MP4.
2. A web page can tell, without bothering visitors who do not have Copycat,
   whether Copycat is running.
3. A site the user has not allowed cannot change the clipboard.
4. An allowed site cannot use Copycat to reach devices on the user's own
   network.
5. Anyone can download a signed, notarized build from GitHub Releases and
   open it without a Gatekeeper warning.

### Out of scope (version 1)

- Windows and Linux.
- Auto-update, Homebrew cask, DMG installer.
- Publishing `copycat.js` to npm or a CDN. It lives in this repo; sites copy it.
- Copying text or HTML (the browser already does this).
- Any change to the Clip project. Clip's web Copy button is a separate spec.

## Decisions taken

| Question | Decision |
|---|---|
| Platforms | macOS only (14 Sonoma or later) |
| Who installs it | Other people too: signed with Developer ID and notarized |
| How the page talks to the app | Local HTTP server on `127.0.0.1` (approach A). A custom `copycat://` link was rejected: the page cannot detect the app. A cross-platform toolkit was rejected: macOS only. |
| Which sites may use it | Ask the user the first time, then remember the answer |
| `/ping` | Answers any site, so pages can decide whether to show Copy. Any site can therefore tell that Copycat is installed; accepted. |
| Snippet distribution | `js/copycat.js` in this repo only |
| Name | Copycat |

## Architecture

One native app: Swift, SwiftUI `MenuBarExtra`, no Dock icon (`LSUIElement`).
The Xcode project is generated with XcodeGen from `project.yml`.

```
web page ──copycat.js──► Server ──► Permissions ──► Fetcher ──► Pasteboard writer
                         127.0.0.1    (ask once)      (download)    (NSPasteboard)
                            │                                          │
                            └──────────────── Feedback ◄───────────────┘
                                         (icon, sound, notification)
```

| Unit | Job | Depends on |
|---|---|---|
| Server | Listens on `127.0.0.1:47823` only. Parses HTTP/1.1, answers `GET /ping`, `POST /copy` and CORS preflight. Reads the `Origin` header. | Network.framework |
| Permissions | Stores each origin's answer (granted or denied). Shows the prompt for a new origin. Enforces one prompt at a time, one copy at a time per origin, 30 copies a minute per origin. | UserDefaults, AppKit |
| Fetcher | Downloads the file: https only, public addresses only, size and time limits. Saves it to the cache folder. | URLSession |
| Type detector | Works out the file type and a safe file name. Pure functions. | — |
| Pasteboard writer | Writes the file to the clipboard in the formats apps read. | AppKit `NSPasteboard` |
| Feedback | Icon state, sound, failure notification. | AppKit, UserNotifications |
| Menu | Status, allowed and denied sites, sound on or off, open at login, version, quit. | SwiftUI, `SMAppService` |
| `js/copycat.js` | Browser API for web pages. | — |

Each unit is testable on its own. The Server only knows a `CopyService`
protocol; the Fetcher, Type detector and Pasteboard writer do not know HTTP
exists.

## HTTP interface

Bound to `127.0.0.1` (and `::1`) on port `47823`. Never on another interface.

Every response carries:

```
Access-Control-Allow-Origin: <the request's Origin>
Vary: Origin
Content-Type: application/json
```

Preflight (`OPTIONS`) answers `204` with
`Access-Control-Allow-Methods: GET, POST`,
`Access-Control-Allow-Headers: Content-Type`, and
`Access-Control-Allow-Private-Network: true` for browsers that still send the
older Private Network Access preflight.

A request without an `Origin` header gets `403`. Origins are compared as
`scheme://host[:port]`, lower-cased.

### `GET /ping`

No prompt, no rate limit beyond the server's general limits.

```json
{ "app": "copycat", "version": "1.0.0", "permission": "granted" }
```

`permission` is `granted`, `denied` or `prompt` for the requesting origin.

### `POST /copy`

Body (JSON, at most 8 KB):

```json
{ "url": "https://example.com/a.gif", "type": "image/gif", "name": "a.gif" }
```

`type` and `name` are optional hints.

Sequence:

1. Validate the body. Bad JSON or a missing `url` → `bad_request`.
2. Permissions: denied → `denied` at once. Unknown → show the prompt and hold
   the request up to 60 seconds. Another prompt already open, or a copy from
   the same origin in progress → `busy`. Over 30 copies in the last minute
   → `busy`.
3. Fetcher downloads the file.
4. Type detector decides the type and name.
5. Pasteboard writer writes the clipboard.
6. Feedback shows success.
7. Answer `{ "ok": true }`.

Failure answers `{ "ok": false, "error": "<code>" }` with these codes:

| Code | HTTP | Meaning |
|---|---|---|
| `bad_request` | 400 | Body is not valid JSON, too big, or has no `url` |
| `bad_url` | 400 | Not `https`, has a user name or password, or not a valid URL |
| `blocked_address` | 400 | The host resolves to a private, loopback or link-local address |
| `denied` | 403 | The user refused this origin |
| `busy` | 429 | A prompt or a copy is in progress, or the rate limit is reached |
| `too_large` | 413 | Over the size limit |
| `fetch_failed` | 502 | The download failed or returned a non-2xx status |
| `timeout` | 504 | The download or the user's answer took too long |

Server limits: request line and headers at most 16 KB in total; the whole
request must arrive within 5 seconds; at most 16 open connections; anything
else → connection closed.

## Permissions

Stored in UserDefaults as `{ origin: "granted" | "denied" }`.

The prompt is a small floating window brought to the front:

> **Allow example.com to copy files to your clipboard?**
> Full origin in small text: `https://example.com`
> [Deny] [Allow]

Closing the window counts as no answer (the request gets `timeout`), not as
Deny, so a closed window can be asked again later.

The menu lists allowed and denied sites, each with Remove.

## Fetcher

- Scheme `https` only. A development setting (off by default, in the menu
  under a hidden Option-click) also allows `http://localhost` and
  `http://127.0.0.1`.
- URLs with a user name or password are refused.
- Address check: the host is resolved first; any address in `127.0.0.0/8`,
  `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`,
  `100.64.0.0/10`, `0.0.0.0/8`, `::1`, `fc00::/7`, `fe80::/10`, or an
  IPv4-mapped form of these is refused. The same check runs on every redirect
  (URLSession task delegate), and a redirect to a non-https URL is refused.
- Size limit 100 MB. Enforced while streaming, so a server that sends no
  `Content-Length`, or lies about it, is cut off at the limit.
- Timeouts: 10 seconds without any data, 60 seconds in total.
- No cookies, no credentials, no cache.
- Saves to `~/Library/Caches/Copycat/<uuid>/<name>`. On start and after each
  copy, keeps the 20 newest folders and deletes any older than 24 hours.

## Type detector

Type, in this order:

1. Magic bytes: GIF (`GIF87a`/`GIF89a`), PNG, JPEG, WebP (`RIFF....WEBP`),
   MP4/MOV (`ftyp` box at offset 4).
2. The `type` hint from the page.
3. The response `Content-Type`.
4. The URL's extension.
5. Otherwise `application/octet-stream`.

Name: the `name` hint; otherwise the last URL path component; otherwise
`copycat-<yyyyMMdd-HHmmss>`. Path separators, control characters and leading
dots are removed; length capped at 120 characters; the extension is replaced
with the one matching the detected type.

## Pasteboard writer

One `NSPasteboardItem`, after `clearContents()`:

| Detected type | Formats written |
|---|---|
| GIF | `public.file-url` and `com.compuserve.gif` data |
| PNG, JPEG, WebP | `public.file-url` and the image data under its UTType |
| MP4, MOV | `public.file-url` only |
| Anything else | `public.file-url` only |

`public.file-url` is what Finder writes when copying a file, so most apps
paste it as an attachment. Which format each app actually reads is not
documented; step 1 of the build (paste test) checks it, and this table is
adjusted to the results.

## Feedback

| Moment | Effect |
|---|---|
| Download takes over 0.3 seconds | Menu bar icon pulses |
| Copied | Icon shows a check mark for about 1 second; system sound "Tink" unless sound is off |
| Failed | Icon shows "!" for about 2 seconds; macOS notification with the reason |

Notification permission is requested the first time a failure needs one.

## `js/copycat.js`

Plain JavaScript, no dependencies, under 2 KB, works as a classic `<script>`
(sets `window.Copycat`) and as an ES module export.

```js
await Copycat.status();   // "ready" | "unknown" | "absent"
await Copycat.copy(url, { type, name });
// → { ok: true } | { ok: false, error }
```

`status()`:

- In Chrome, it first reads the local network permission with
  `navigator.permissions.query`. If the state is `prompt`, it returns
  `"unknown"` **without** pinging, so visitors without Copycat never see
  Chrome's local network prompt on page load.
- Otherwise it pings with a 1-second timeout. A valid `{ app: "copycat" }`
  reply → `"ready"`. No answer, an error, or a reply from another program
  → `"absent"`.
- In browsers without that permission (Safari, Firefox) it pings directly.

`copy()` calls `POST /copy`. It must be called from a click handler, so that
Chrome's local network prompt, if it appears, follows a user action. Network
errors become `{ ok: false, error: "absent" }`.

The fetch uses whatever request annotation Chrome currently requires for
loopback addresses (`targetAddressSpace`); the exact value is checked during
the build against the running Chrome version.

Suggested page logic: show Copy when `status()` is `ready` or `unknown`;
hide it when `absent`.

## Packaging

- Hardened runtime, no App Sandbox, no extra entitlements.
- Signed with a Developer ID Application certificate.
- `scripts/release.sh <version>`:
  1. `xcodegen generate`
  2. `xcodebuild archive`, export with Developer ID
  3. `xcrun notarytool submit --wait`
  4. `xcrun stapler staple`
  5. Zip `Copycat.app` with `ditto`, create the GitHub Release on
     `plosson/copycat` with `gh release create`, attach the zip.
- The version shown in the menu comes from `CFBundleShortVersionString`.

## Testing

Adversarial tests first; happy paths only where needed to prove the wiring.

**Paste test (first, throwaway).** A tiny script writes a known GIF and a
known MP4 to the clipboard in the formats above. Paste by hand into
Messages, Slack, WhatsApp, Discord, Telegram, Mail, Notes and Gmail in
Chrome. Record which formats each app reads; adjust the Pasteboard writer
table.

**Unit tests (XCTest):**

- Type detector: GIF bytes named `.mp4`; empty file; 3-byte file; HTML error
  page served as `image/gif`; WebP with a wrong RIFF size; names `../../etc`,
  `.hidden`, 500 characters, null bytes, emoji, no extension.
- URL and address checks: `http:`, `file:`, `javascript:`, `data:`,
  `https://user:pw@host`, private IPv4 and IPv6 literals, IPv4-mapped IPv6,
  decimal and octal IP forms (`https://2130706433`), a public name that
  resolves to a private address.
- Permissions: denied origin never prompts; second prompt while one is open →
  `busy`; same origin twice in parallel → `busy`; 31st copy in a minute →
  `busy`; closing the window → `timeout`, origin still unknown; origins
  differing only by port or scheme are distinct.

**Server tests (raw sockets against a running server with a fake
`CopyService`):** no `Origin`; `GET /copy`, `PUT /copy`; preflight headers;
body over 8 KB; invalid JSON; headers over 16 KB; a client that sends half a
request and stalls; 50 parallel connections; connection from a non-loopback
interface refused.

**Fetcher tests (local test server, development setting on):** over the
size limit without `Content-Length`; `Content-Length` lower than the real
body; a stalled download; 404; redirect to `http:`; redirect to a private
address.

**Snippet tests (`bun test`, fake `fetch` and `navigator.permissions`):**
Copycat not running; ping times out; another program answers on the port
with HTML or with JSON that is not Copycat's; permission state `prompt` →
`unknown` with no fetch made; `copy()` network error → `absent`.

## Build order

1. Paste test; adjust the Pasteboard writer table.
2. Type detector and its tests.
3. Pasteboard writer.
4. Fetcher with address checks and its tests.
5. Permissions and prompt.
6. Server and its tests.
7. Menu and Feedback.
8. `js/copycat.js` and its tests; a demo page `js/demo.html`.
9. End-to-end check in Chrome, Safari and Firefox.
10. Release script; first signed, notarized release.

Each step ends with the tests passing before the next one starts.
