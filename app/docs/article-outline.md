# Article outline: the launch write-up

**Working title:** *Why your Mac scatters your windows after sleep, and what it
takes to put them back*

**Where it goes:** your own blog, then Show HN, r/macapps, r/MacOS.

**Why an article and not a repo link:** a GitHub link is a product announcement,
and product announcements from unknown developers sink. A technical write-up
about a problem thousands of people have and nobody has named is something
people forward. The repo is the evidence at the bottom of it, not the pitch.

**Target length:** 1500–2500 words. Long enough to be substantive, short enough
to finish.

**Tone:** explain the problem honestly, including the parts you didn't solve.
The limitations section is not a weakness in this format — on Hacker News it is
the single most credibility-building thing you can include.

---

## 1. The hook: a problem people have but haven't named

Open with the concrete experience, not the software.

You close the lid, come back, and your workspace is gone. Every window has been
swept onto the built-in display and then scattered again as the external screens
came back. You spend a minute dragging things back. You do this every day and
you've stopped noticing.

Then the detail that makes this an article rather than an ad: **when I asked
colleagues, most said they didn't have this problem.** They did. They'd just
never articulated it — they drag three windows back and think nothing of it. It
only becomes visible when you have a dozen windows in a specific arrangement.

That's a genuinely interesting observation about invisible friction, and it's
the emotional entry point for readers who will recognise themselves.

## 2. Why it happens

Short, factual, no speculation. Do not overclaim — describe the mechanism you
can actually observe.

- When displays sleep or disconnect, macOS removes them from the display list.
- Windows on a display that no longer exists have to go somewhere, so they're
  relocated to the remaining display.
- On wake, displays return asynchronously — and often at the wrong resolution
  first, then corrected.
- Windows are laid out against whatever the arrangement was at that instant.
- Nothing in macOS records where they were before.

Explain why setups differ, because this is the part your colleagues disproved
for themselves: a USB-C dock or DisplayLink adapter makes displays vanish
entirely, while a monitor on direct DisplayPort that only enters standby often
doesn't trigger it at all. Same OS, opposite experience.

## 3. Why the obvious fix isn't obvious

This is the transition from "annoying" to "interesting", and it's where a
technical reader decides whether to keep reading.

State the problem precisely: restoring a layout is not about moving windows.
Moving a window is three Accessibility API calls. The hard part is knowing
**which window is which**, and macOS gives you almost nothing to work with.

- `CGWindowID` doesn't survive an app restart.
- Titles change constantly — a browser tab switch renames the window.
- Two windows of the same app are externally identical.
- `AXIdentifier` exists but most apps never set it.
- There is no stable, persistent window identity. At all.

So it's a matching problem between a set of saved windows and a set of live
windows, under uncertainty.

## 4. The failure mode that actually matters

The insight that makes the design non-obvious, and the strongest paragraph in
the article.

Users don't notice a window landing 20 points off. They notice **two windows
swapping places**. A layout restore that's 90% accurate but occasionally
transposes your editor and your terminal feels broken in a way that a slightly
imprecise one never does.

That means matching has to be strictly 1:1. A greedy per-window best-match will
happily assign the same physical window twice, or cascade a single wrong match
into a scrambled layout.

This reframes the whole problem as an assignment problem, not a lookup.

## 5. The matching cascade

Walk through the levels with a sentence each on why they're in that order and
what each one costs you.

1. **Reservation** — a window claimed by another snapshot in this batch is off
   limits. This is what structurally prevents transposition.
2. **`CGWindowID`**, but only when the owning process is provably the same one
   captured — verified with pid *and* process launch date, because pids get
   reused.
3. **`AXIdentifier`**, when the app bothers to provide one.
4. **Exact title**, then **fuzzy title**. Describe the scoring honestly: token
   overlap and edit similarity, a minimum score, and a required margin over the
   runner-up. The margin is the important part — an ambiguous match is worse
   than no match, because no match leaves the window alone while a wrong match
   moves it somewhere actively wrong.
5. **Frame proximity**, within a threshold.
6. **Single candidate** — one window, one snapshot, done.

Emphasise the principle: **refusing to guess is a feature.** Below a confidence
threshold, doing nothing is the correct behaviour.

## 6. The second hard problem: when

Most readers will not have thought about this, which makes it a good second act.

Displays don't come back at once. A DisplayLink dock can take five seconds and
arrive in waves, each one triggering a reconfiguration. Restore too early and
you write positions into an arrangement that's about to be replaced — you've
done work that's not only wasted but wrong.

Describe the settle logic: watch `CGDisplayRegisterReconfigurationCallback`,
wait for a quiet period after the last event, then wait a little longer, because
displays report themselves ready before macOS has finished relocating windows.

Then the design decision that separates Perch from the competition, and the
paragraph most likely to be quoted:

**The moving machinery is equally reliable whether a human or a timer triggers
it. What a human supplies for free is judgement — "now is the right moment" and
"this is the layout I want." Automation has to guess both.** So the default is
detect-and-offer, not detect-and-act. Existing tools in this space restore
blindly, and the most common complaint about them is exactly that.

## 7. What I didn't solve

Do not skip this and do not soften it. On HN this section earns more trust than
everything above it.

- **Spaces.** `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` only sees the
  active desktop. The public API offers nothing else; the private one is a
  permanent maintenance liability. Windows on other Spaces are invisible to
  Perch. No competitor really solves this either.
- **Minimized and fullscreen windows** aren't recorded, though they can be
  restored — Perch will pull a window out of fullscreen to place it.
- **Apps with poor accessibility metadata** are genuinely hard, and sometimes
  the honest answer is to leave the window where it is.

## 8. Close

Two paragraphs, no hard sell.

It's free and open source, Apache 2.0. Say plainly why: it works around a defect
in someone else's platform, Apple could fix it in any release, and building a
business on that footing didn't make sense. Say that you'd rather the code be
useful than idle.

Then the link, and an invitation to tell you if it gets your particular setup
wrong — with the note that the restore report will say which rule matched, which
makes those reports actually actionable.

---

## Practical notes

- **Include a GIF near the top.** Windows scattering, one action, windows back.
  Nothing in the text conveys it as fast.
- **Show real code, sparingly.** Two short Swift snippets at most — the fuzzy
  score and the reservation check. Enough to prove the article is written by the
  person who built it.
- **Keep business decisions out of the article.** Focus on
  the problem. The Apache badge says the rest.
- **Have answers written down before you post:** why not Spaces, why
  Accessibility permission is needed, why not the Mac App Store (Accessibility
  needs an unsandboxed app), how this differs from Rectangle (not a tiler) and
  Moom (it asks instead of guessing).
- **Post in the morning, European time, midweek.** Then stay available for a few
  hours — comment response in the first hour largely determines whether a Show
  HN survives.
