# Contributing to PureMac

Thank you for wanting to make PureMac better! You don't have to write code to help — reporting a
bug, suggesting an idea or improving a translation matters just as much.

## Ways to help

- **🐞 Report a bug.** [Open an issue](https://github.com/OpenAppBox/PureMac/issues/new/choose) and
  tell us what you did, what you expected and what happened. Your PureMac and macOS versions help a lot.
- **💡 Suggest an idea.** Tell us what you're trying to get done, not only the feature you have in
  mind — it helps us find the best way to build it.
- **🧹 Point out a cache we miss.** Know a folder that an app always rebuilds by itself? Suggest it
  as a Smart Clean rule, with a link to where its developer documents it.
- **🌍 Improve a translation.** PureMac speaks 23 languages. If something reads oddly in yours,
  tell us or send a fix.
- **🛠️ Contribute code.** See below.

Found a security problem? Please don't post it publicly — follow [SECURITY.md](SECURITY.md).

## What makes a change fit PureMac

PureMac makes promises to the people who use it. Every change has to keep them:

1. **Nothing is removed without review.** Every removal goes through the review screen and needs a confirmation.
2. **Trash only.** PureMac never deletes permanently and never empties the Trash.
3. **Conservative by default.** Only things an app or tool rebuilds by itself may be chosen automatically. Anything personal, risky or uncertain waits for the user.
4. **Protected stays protected.** System files, other users' data, Mail, Messages, Photos, keychains and iCloud Drive are off-limits.
5. **Private and offline.** No network code, no analytics, no tracking — not even "anonymous".
6. **No special powers.** No administrator password, no privileged helpers, no private Apple interfaces.
7. **Honest.** Real measurements, no scare tactics, no "boosters".
8. **Calm and accessible.** Respect Reduce Motion, keep the interface fast, and make it work with VoiceOver.

If a change would bend one of these, let's talk about it in an issue first.

## Working on the code

You need macOS 14 or later and Xcode 26 or later. There are no third-party dependencies.

```bash
git clone https://github.com/OpenAppBox/PureMac.git
cd PureMac
open PureMac.xcodeproj
```

- The app lives in `PureMac/`; the engine (scanning, rules, cleanup) is the `PureMacKit` package in
  `Packages/PureMacKit/`.
- Run every test with `Scripts/test.sh`. Pull requests need it to pass.
- Tests that remove files work only inside temporary folders and never touch your real home folder
  or Trash. Please keep it that way in new tests.
- **New or changed text** needs to be in the string catalogs for all 23 languages; the localization
  tests tell you what's missing. If you can't translate, say so in your pull request and we'll help.
- **New Smart Clean rules** need a narrow, documented location, an honest explanation of what
  happens after removal, and tests proving they don't match anything else.

### Pull requests

1. For anything bigger than a small fix, open an issue first so we can agree on the approach.
2. Keep each pull request focused on one change.
3. Describe what changed and why, and how you tested it. Screenshots help for anything visible.
4. A maintainer reviews every pull request. We may ask for changes — that's normal, and thank you
   for your patience.

## Licensing of contributions

PureMac is released under the [GNU General Public License v3.0](LICENSE). By submitting a
contribution, you confirm that you have the right to submit it, and you agree that:

- your contribution is licensed under the GPL-3.0, like the rest of PureMac, and
- OpenAppBox may also distribute your contribution as part of the official PureMac app through app
  stores such as the Mac App Store, under those stores' terms.

## Be kind

Everyone taking part is expected to follow our [Code of Conduct](CODE_OF_CONDUCT.md).
