---
layout: post
title: "What Would a Week of Claude Code Cost at API Prices?"
seo_title: "Reading API Value and Weekly Quota in Agent Sessions Economics"
description: "One week of Claude Code sessions adds up to $390 at API prices. A closer look at Opus shows what that figure can tell you about a subscription."
date: 2026-11-23
published: true
image: /assets/economics-claude-week.png
summary: >-
  One week of Claude Code priced out at $390. Here’s how to use your own
  sessions to check a renewal, find a change worth making, and decide
  when higher effort earns its keep.
---

**$390 for seven days of Claude Code.** That’s the value of the usage recorded on this Mac at published API prices. If your subscription already covered a week like this, $390 is what you’d compare against the fee you paid. If those seven days were a sprint to get an app out the door and you barely opened Claude the rest of the month, multiplying by four would give you a pretty bad estimate.

A reader in r/ClaudeAI asked, “What API cost do you think equals the $20/month Claude Pro plan?” You can get closer to the answer you need by pricing a month of your own work. [Original Reddit question](https://www.reddit.com/r/ClaudeAI/comments/1y0639j/what_api_cost_do_you_think_equals_the_20month/)

### Would I renew the subscription?

Open **Analytics → Economics** in Agent Sessions. Choose **Last 30 Days → Claude Only → All Projects**. Read **API-equivalent value** and **Price coverage** together. Check that the period includes both the days you shipped and the days you barely coded. If you also use Claude on another machine, account for that work before drawing a conclusion from this Mac.

Compare that estimate with what you actually paid over a comparable period, including any extra usage charges. If the API estimate is comfortably higher, the plan covered the work you needed, and you expect another month like it, I’d renew. If the estimate is comfortably lower, coverage is good, and coding is the main thing you buy the plan for, metered billing is worth a look. A close result gives me little reason to switch. Even cache behavior can move the bill: Max Nardit priced the same million-token Opus cache write at $5 for five minutes and $8 for an hour. [Nardit’s cache experiment](https://max.nardit.com/articles/claude-code-cost)

Felipe Fontoura priced four busy days of his own at $626. His advice: “Run it over a normal month, not your busiest week, and compare.” [Fontoura’s subscription audit](https://felipefontoura.com/articles/is-claude-max-worth-it/)

### Where would I look for savings on my app?

For a project budget, switch **All Projects** to the app you’re building. For a renewal, leave your side projects in: the same subscription paid for those too. The screenshot and chart below use the same seven days of Claude Code activity across all projects. Economics could price all **3,904 records from 65 sessions**.

<figure class="post-figure">
  <a href="{{ '/assets/economics-claude-week.png' | relative_url }}"><img src="{{ '/assets/economics-claude-week.png' | relative_url }}" alt="Seven days of Claude Code usage at $390 API-equivalent value, with the high-effort Opus row selected." loading="lazy"></a>
  <figcaption>High-effort Opus is selected: $205 across 25 sessions. Select the screenshot for a full-size view.</figcaption>
</figure>

Suppose I want to cut a week like this by a quarter at API prices, roughly $97.50. Which setting is worth a closer look? Here’s the same $390 broken down by model and effort.

<style>
.economics-breakdown {
  padding: clamp(14px, 3vw, 28px);
  border: 1px solid var(--hair-strong);
  border-radius: var(--radius);
  background: var(--bg-elev);
  scroll-margin-top: 80px;
}
.economics-breakdown h3 { margin: 0 0 16px; }
.economics-breakdown ul { margin: 0; padding: 0; list-style: none; }
.economics-breakdown li {
  display: grid;
  grid-template-columns: 10rem minmax(0, 1fr) 5rem 3.5rem;
  gap: 12px;
  align-items: center;
  padding: 9px 0;
  margin: 0;
  font-size: 15px;
  line-height: 1.3;
}
.economics-breakdown .setting { font-weight: 600; }
.economics-breakdown small { color: var(--ink-2); font-size: .85em; font-weight: 400; }
.economics-breakdown .plot { height: 10px; }
.economics-breakdown .plot i { display: block; height: 100%; background: var(--blue); }
.economics-breakdown .amount, .economics-breakdown .share {
  text-align: right;
  font-variant-numeric: tabular-nums;
}
.economics-breakdown .share { color: var(--ink-2); }
.economics-breakdown figcaption { margin-top: 16px; text-align: left; }
@media (max-width: 620px) {
  .economics-breakdown li {
    grid-template-columns: minmax(0, 1fr) auto 3.25rem;
    grid-template-areas: "label amount share" "bar bar bar";
    gap: 4px 8px;
  }
  .economics-breakdown .setting { grid-area: label; }
  .economics-breakdown .amount { grid-area: amount; }
  .economics-breakdown .share { grid-area: share; }
  .economics-breakdown .plot { grid-area: bar; height: 5px; }
}
</style>

<figure class="post-figure economics-breakdown" id="weekly-spending" aria-labelledby="weekly-spending-title">
  <h3 id="weekly-spending-title">Where the $390 went</h3>
  <ul role="list">
    <li>
      <span class="setting">Opus 5.5 <small>High</small></span>
      <span aria-hidden="true" class="plot"><i style="width:100.000%"></i></span>
      <span class="amount">$204.61</span><span class="share">52.5%</span>
    </li>
    <li>
      <span class="setting">Fable 5.2 <small>Medium</small></span>
      <span aria-hidden="true" class="plot"><i style="width:40.428%"></i></span>
      <span class="amount">$82.72</span><span class="share">21.2%</span>
    </li>
    <li>
      <span class="setting">Opus 5.5 <small>Medium</small></span>
      <span aria-hidden="true" class="plot"><i style="width:31.690%"></i></span>
      <span class="amount">$64.84</span><span class="share">16.6%</span>
    </li>
    <li>
      <span class="setting">Fable 5.2 <small>High</small></span>
      <span aria-hidden="true" class="plot"><i style="width:16.250%"></i></span>
      <span class="amount">$33.25</span><span class="share">8.5%</span>
    </li>
    <li>
      <span class="setting">Sonnet 5.5 <small>Medium</small></span>
      <span aria-hidden="true" class="plot"><i style="width:1.838%"></i></span>
      <span class="amount">$3.76</span><span class="share">1.0%</span>
    </li>
    <li>
      <span class="setting">Sonnet 5 <small>Medium</small></span>
      <span aria-hidden="true" class="plot"><i style="width:0.215%"></i></span>
      <span class="amount">$0.44</span><span class="share">0.1%</span>
    </li>
    <li>
      <span class="setting">Opus 5.5 <small>Low</small></span>
      <span aria-hidden="true" class="plot"><i style="width:0.103%"></i></span>
      <span class="amount">$0.21</span><span class="share">0.1%</span>
    </li>
  </ul>
  <figcaption>API-equivalent value and share of the week’s total. Seven days ending November 23 at 8:03 p.m. Pacific.</figcaption>
</figure>

**Opus 5.5 High accounts for $205, just over half the week.** Halving the cost of that work would save about $102 and meet that target. Even eliminating all medium-effort Opus usage would save only about $65. I’d start by looking at the high-effort sessions for routine work that could run at medium, then check whether retries eat up the savings.

### Will I have enough quota to finish a release?

Check the provider’s **remaining allowance and reset time** before starting a long review. The $390 tells you what the recorded work was worth at API prices. Estimating a share of weekly quota also requires a calibration against the provider’s meter. This snapshot contains priced usage only, so the weekly quota estimate is unavailable.

SemiAnalysis bought Anthropic and OpenAI subscriptions and “randomly ran long horizon coding tasks until we exhausted the weekly limit.” They measured how much work filled those plans in their experiment. If you’re halfway through a release, your own balance tells you more about what you can do tonight. [SemiAnalysis’s June 10 experiment](https://x.com/SemiAnalysis_/status/2064815044085318040)

### Is high effort worth it for a bug fix?

In **API $ / timed hour**, high-effort Opus averaged **$9.73** over 18.1 timed hours. Medium averaged **$7.97** over 6.7. Those sessions did different work. A lower hourly rate can still cost more per fix if it takes longer or needs another attempt. Each rate uses only activity the app could time and requires at least 15 covered minutes.

Here’s the comparison I’d actually run. Pick a recent bug with a regression test that fails before the fix. Give medium and high the same starting commit, issue description, and test, in separate sessions. For each run, jot down three things: **did the test pass, how many times did I have to step in, and what was the API-equivalent value of the whole attempt, retries included?** If medium gets you to a fix you’d merge with the same amount of supervision, try it first on the next similar bug. If high saves two rounds of explaining the problem again, you’ve learned where the extra effort buys you something.

For a Codex project, choose **Codex Only** and repeat the comparison with your own sessions. Codex uses its own quota calibration when one is available.
