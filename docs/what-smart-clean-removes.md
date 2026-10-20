# What Smart Clean removes

Smart Clean only ever suggests things your Mac can **rebuild or download again by itself**. This page
lists every kind of item it looks for, what happens after it's gone, and whether PureMac picks it
for you.

Everything Smart Clean removes goes to the **Trash** first. You see the full list before anything
moves, and you can put any item back until you empty the Trash yourself.

**How to read the tables**

- ✅ **Chosen for you** — safe to remove; it's part of the main "Ready to clean" total.
- ➕ **One tap** — offered under *Free up more*, with a line explaining what it costs you.
- 👀 **Your call** — listed for you to review; never chosen automatically.

---

## Caches of the apps you use

Apps keep caches to start faster and avoid downloading the same things twice. Remove them, and the
app simply builds them again.

| What | | What happens afterwards |
|---|---|---|
| App caches of installed apps | ✅ | The app recreates its cache; it may start a little slower once. |
| Web caches of desktop apps (code editors, chat apps and other apps built on web technology) | ✅ | The app re-downloads images and recompiles scripts; the first launch is slower. Sign-ins and settings are never touched. |
| Browser caches of Chrome, Firefox, Brave and Edge | ✅ | Web pages load from the network again; sites may be slower the first time. |
| Slack, Discord and Visual Studio Code caches | ✅ | Images are downloaded again; the first launch is slower. |
| Downloaded app updates | ✅ | The app downloads its next update again when one is available. |

> **Apps you're using are held back.** If an app is open, its caches wait. Smart Clean shows them
> separately, and *Quit & Include* closes those apps politely (never forcefully) and adds them.

## Old logs and crash reports

| What | | What happens afterwards |
|---|---|---|
| App logs not changed for 30 days | ✅ | Those old logs are no longer available for troubleshooting. |
| Crash and diagnostic reports older than 30 days | ✅ | Those reports can no longer be sent to a developer. |

## Package manager and developer caches

| What | | What happens afterwards |
|---|---|---|
| Homebrew, pip, Yarn and CocoaPods download caches | ✅ | Packages are downloaded again when you need them. |
| Developer tool caches (Go, Swift Package Manager, pnpm, TypeScript and others) | ✅ | Each tool rebuilds what it needs the next time it runs. |
| Xcode DerivedData, device support files and simulator caches | ➕ / 👀 | The next build is a full rebuild. Offered in one tap when unused for two weeks; otherwise your call. |
| npm cache | ➕ / 👀 | npm downloads packages again; offline installs stop working until it does. Offered in one tap when unused for two weeks. |
| Browser builds for automated tests (Playwright, Cypress) | ➕ / 👀 | You'd reinstall them with one command, which downloads several hundred megabytes. Offered in one tap when unused for two weeks. |

## Installers and leftovers

| What | | What happens afterwards |
|---|---|---|
| Disk images and installer packages in Downloads older than a month | ➕ | Apps installed from them keep working; you'd download the installer again to reinstall. |
| Leftovers of apps you already deleted ("Likely") | ➕ | Nothing — the app they belonged to is gone. Uncertain leftovers stay in Orphaned Remnants for you to review. |

---

## What Smart Clean never touches

- Your documents, photos, music, videos and downloads (other than old installers you choose)
- Anything inside the Photos, Music or TV libraries, Mail, Messages, your keychains or iCloud Drive
- App settings, sign-ins, saved passwords and browser profiles
- System files and other users' files
- Xcode archives — they may be the only copy of a build you shipped
- Anything PureMac isn't sure about

## How the rules are made

Every Smart Clean rule is narrowly scoped to one documented location, reviewed by people, and
covered by automated tests that check it never matches anything outside that location. The rules
are part of the source code, so anyone can read exactly what they do.

Want PureMac to know about a cache it's missing? [Suggest it](https://github.com/OpenAppBox/PureMac/issues/new/choose).
