# Support

Perch is a free side project maintained in spare time. This page sets honest
expectations so nobody is disappointed.

## What I will do

- Fix bugs that make Perch lose or corrupt your saved layouts. These are the
  only issues I treat as urgent.
- Fix breakage caused by new macOS releases, as time allows.
- Read every issue, even if I don't reply to every one.
- Review pull requests.

## What I probably won't do

- Add Spaces / virtual desktop support. See the README for why — it needs
  private API and would be a permanent maintenance liability.
- Turn Perch into a tiling window manager. That's a different product and
  [Rectangle](https://rectangleapp.com) already does it well.
- Add per-application rules, scripting, or an automation API.
- Guarantee a response time. There isn't one.

If something here matters enough to you, a pull request is far more likely to
get it done than an issue.

Use the repository's [issue forms](../../issues/new/choose) for reproducible
bugs and focused feature proposals. Use
[Discussions](../../discussions) for questions and ideas that are not bugs.

## Before opening an issue

Most reports come down to one of these:

**Windows don't move at all.** Check that Perch has Accessibility permission in
System Settings → Privacy & Security → Accessibility. If it's already listed,
remove it and re-add it — the permission can go stale after an app update.

**Some windows are skipped when saving.** Minimized and fullscreen windows are
skipped by design, as are windows on Spaces other than the active one. This is
documented in the README and is not going to change.

**A window lands in the wrong place, or two windows swap.** Open the restore
report from the menu bar. It tells you which rule matched each window. If it
says the match was fuzzy, include that report in your issue; changing titles or
poor Accessibility metadata can make two windows genuinely ambiguous.

**Automatic restore doesn't fire.** The menu bar shows the reason for the last
automatic decision. Read it before reporting — it usually says exactly what
happened ("topology unchanged", "no layout for this arrangement"). If your dock
is slow, try raising the settle timeout in Settings.

**The download link is missing.** A public build exists only after a GitHub
Release contains an asset named exactly `Perch.dmg`. Check the
[Releases page](../../releases); source snapshots are not installable builds.

## What to include in a bug report

Without these, a report usually can't be acted on:

- macOS version and Mac model
- How your displays are connected (direct HDMI/DisplayPort, USB-C dock,
  DisplayLink, clamshell)
- The diagnostics export: Settings → About → Export Diagnostics. It contains
  no window titles or layout names.
- What you expected and what happened instead

## Security

For anything security-sensitive, don't open a public issue. Email
hello@codeandlive.cz instead.
