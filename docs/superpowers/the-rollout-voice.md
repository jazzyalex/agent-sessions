# The Rollout — voice & copy guardrails

Status: **Living reference** (read before drafting any post or social copy)
Excluded from the public site via `_config.yml`.

This is the standing style guide for "The Rollout" and all Agent Sessions content
(blog, X, LinkedIn, Reddit). The goal: writing that reads like a sharp engineer
wrote it, not a content model. Honest, specific, a little dry.

## The persona (who's "speaking")

Based on the founder's observed register (Alex, `@jazzyalex`) plus the product's
own philosophy. Calibrate against real samples before publishing: the founder's
tweets and the drafts in `Marketing/` (e.g. the Reddit drafts) are the ground
truth for public voice — pull them and match the cadence.

- **Terse and decisive.** Says the thing, moves on. Low ceremony. In chat this
  shows up as lowercase, fast, typo-tolerant ("comit push", "ok"). In prose it
  becomes: short sentences, active voice, no throat-clearing.
- **Craft-obsessed, macOS-native sensibility.** Cares about HIG, honest UI,
  ambitious redesigns over parameter tweaks. Respects details and expects the
  reader to as well.
- **Honest over hype.** The product's whole thesis is "never cry wolf" and
  "explicit status over a spinner." The copy must embody the same value: no
  overclaiming, name the tradeoffs out loud. Trust is the brand.
- **Dry, a little irreverent.** Confident, not arrogant. A wry aside here and
  there. Talks to the reader as a peer engineer, never as a "user" or a lead.

## Voice principles

1. **Lead with the reader's problem, not the product.** The product shows up
   when it's earned, usually two-thirds in.
2. **Show the work.** Real mechanics, real numbers, real file names. Credibility
   is specifics. Vagueness reads as marketing.
3. **Honest about limits.** If something is coarse by design (e.g. Claude's
   projection), say so and explain why. Owning a tradeoff builds more trust than
   hiding it — and it's on-brand.
4. **Short sentences. Active voice. Cut the throat-clearing.** Delete "it's
   worth noting," "in order to," "the fact that."
5. **Peer-to-peer.** You're talking to a fellow developer. Contractions yes.
   Condescension no. Don't explain the obvious.

## Sarcasm dial ("a little sarcastic, but respectful")

- **Aim at the frustration, never the reader.** Fair targets: limits that stop
  you mid-task, dashboards that lie, spinners that mean nothing, telemetry
  nobody asked for. Off-limits: the reader, and competitors by name.
- **One or two dry lines per post, max.** Wit is seasoning, not the meal.
- Calibration example (good): *"A percentage tells you how much you've burned.
  It says nothing about whether you'll reach reset. It's a fuel gauge that only
  shows the size of the tank."*
- Too much (bad): a running bit, snark in every paragraph, punching down.

## Anti-AI-slop banlist (hard rules)

- **Banned words/phrases:** unleash, unlock, harness the power of, in today's
  fast-paced world, game-changer, seamless, effortless, robust, cutting-edge,
  revolutionize, elevate, delve, dive in, supercharge, "it's worth noting,"
  "at the end of the day," "when it comes to," "the world of."
- **No em-dash cadence pileups.** The rhythmic "X — Y — Z, and Z — that's the
  point" tic is the tell of AI prose. Vary sentence structure; use periods.
- **No hedging clusters** ("can help to potentially maybe"). Commit to the claim.
- **No listicle padding** ("Here are 5 ways…"), no fake enthusiasm, no
  exclamation spam.
- **No "In conclusion" / restate-the-intro** closer. End on a real point.
- **No invented stats.** Every number traces to code or a cited doc.
- **No emoji in body copy.** Headers/social: sparingly, if at all.

## Structure defaults

- **Title:** problem-first and concrete. Earn any colon-subtitle; don't reach for
  a buzzword pairing.
- **Open in-scene or on the sharp problem.** Never "In this post we'll…"
- **Captions** read like a person pointing at the screen, not alt-text.
- **CTA:** soft, one line, honest — free, local-only, no telemetry, link. Done.

## Distribution voice

- **X:** one idea, punchy, the founder's actual chat register (lowercase fine).
  ≤280 chars (account is not Premium). ⌘+Return to submit.
- **LinkedIn:** same substance, a little more setup, zero corporate mush.
- **Reddit:** value-first, product last, match the specific sub's norms and
  self-promo rules. Never a press release. Verify the real source before
  referencing anyone's post.

## Litmus test before publishing

1. Could a competitor's marketer have written this? If yes, it's too generic —
   add specifics or cut it.
2. Did we claim anything we can't point to in the code or a cited doc? Cut it.
3. Would Alex say this out loud to another developer? If not, rewrite it.
