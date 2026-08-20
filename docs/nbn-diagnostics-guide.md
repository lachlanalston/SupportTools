# Reading NBN Diagnostics in Carbon: FTTN/FTTB Line State and Loopback Tests

A field guide for interpreting the NBN test results Aussie Broadband exposes in the Carbon portal, so you can tell for yourself whether a service is healthy, marginal, or faulty before (or instead of) asking their techs.

Carbon surfaces the same NBN wholesale diagnostics that Aussie's own support staff use. The two you will see most on FTTN/FTTB copper services are the Line State test and the Loopback test.

## The tests at a glance

| Test | Applies to | What it does | Service impact |
|---|---|---|---|
| Line State | FTTN/B only | Snapshot of the DSLAM (node) port: sync rates, attainable rates, noise margins, attenuation, profile, stability | Brief. The modem must be in sync for results to mean anything |
| Loopback | All NBN techs | Sends test data in both directions between the RSP/nbn network and the premises equipment | Brief interruption while it runs |
| Check Connection | All | Confirms the service looks online from the provider side | None |
| Kick Connection | All | Drops the current session so the CPE reconnects (use when swapping routers) | Disconnects, up to 10 min to restore |
| Port Reset | FTTP/FTTC/FTTN/B | Resets the UNI-D or node port to force a clean resync | Disconnects briefly |
| Stability Profile | FTTN/B only | Applies a more conservative DSL profile to trade speed for stability | Resync; speeds may drop |

## Line State test, field by field

| Field | What it is | How to read it |
|---|---|---|
| Operational Status | Whether the node port has DSL sync with the modem | Up is required for everything else to matter. Down with the modem powered on points at premises wiring, the modem itself, or a port/jumpering fault |
| Service Stability | nbn's classification of the line based on resyncs/errors over the recent history window | STABLE is what you want. Anything else (for example UNSTABLE) is actionable: apply a Stability Profile, wait 48 hours, retest, and escalate if it has not returned to STABLE |
| MAC Address | The modem the node port currently sees | Confirms the right premises is on the right port. Useful in wrong-jumpering disputes and to verify a swapped modem has actually connected |
| DSL Mode | Modulation in use | VDSL2 is correct for FTTN/B. Anything else (ADSL fallback) means the CPE is misconfigured or negotiating badly |
| Estimated Distance to Node | nbn's estimate derived from loop attenuation, not a measured cable run | Indicative only, but the single best predictor of what the line can do. Under ~200 m lines usually support 100 Mbps tiers; roughly 200 to 400 m supports 60 to 100; 400 to 700 m supports 25 to 60; beyond ~700 m lines often struggle to attain 25 (community rules of thumb, and co-existence drags each band down) |
| Physical Profile | Three facts in one string: the speed tier, the DLM state, and the spectrum state. Example: "100/40 Standard 6dB (Co-Existence)" | "Standard 6dB" is the default, clean-history profile. A "Stability" variant or a higher target margin (9dB, 12dB) means the line has a history of drops and DLM or a tech has intervened. "(Co-Existence)" describes the area, not a fault (see below) |
| Attainable Rate | What the line could sync at right now, given its length, noise and profile | Compare it to the plan tier. Comfortably above the tier means the copper supports the plan with headroom. Below the tier means the line physically cannot deliver the plan (see the spec section) |
| Current Sync Rate | The rate the port and modem actually negotiated | nbn caps FTTN sync roughly 10% above the tier to cover protocol overheads (a 100/40 service syncs around 110/44, a 50/20 around 55/22). Sync at or near that cap means the full plan speed is available at the DSL layer. Sync well below both the cap and the attainable rate deserves a port reset and retest |
| Attenuation Average | Aggregate attenuation counter | Frequently comes back NaN or N/A because the DSLAM does not return it. That is a portal quirk, not a fault. Use Loop Attenuation and the distance estimate instead |
| Loop Attenuation | Signal loss across the copper loop, in dB. Lower is better and it scales with distance | Generic DSL bands: under 20 dB outstanding, 20 to 30 excellent, 30 to 40 very good, 40 to 50 good, 50 to 60 poor, over 60 bad. On short FTTN loops expect single digits to low tens for 100 Mbps tiers |
| Noise Margin (SNR margin) | Headroom between the received signal quality and the minimum needed to hold sync, in dB | The target is the number in the profile name (6 dB on Standard). At-target margin means the line is syncing as fast as conditions allow. Margin far above target with sync at the cap means lots of headroom (excellent). Margin at or below ~6 dB and falling means dropout risk and noise ingress. Compare a daytime test to an evening test: big swings point at interference (REIN, crosstalk) |

Portal display quirks to ignore: attenuation labelled in "Mbps", doubled units like "dBdB", and NaN/N/A in the averages. None of those indicate a line problem by themselves.

## The numbers that matter

Sync rate vs tier. The port is capped a little above the tier so that DSL and Ethernet overheads still leave the full plan speed at layer 3. Around 105 or more sync on a 100 tier, or around 44 on a /40 upstream, is "full speed available". A speed complaint on such a line is not a copper problem: look at the customer's router, Wi-Fi, LAN, the device doing the test, or upstream congestion.

Attainable vs tier. Attainable at or above the sync cap: line supports the tier with headroom. Attainable between the tier and the cap: marginal, watch it. Attainable below the tier: the copper cannot deliver the plan. That is not fixed by tickets, it is fixed by the ACCC speed-claims path (below) unless the attainable rate has clearly degraded from the line's own history.

Noise margin. 6 dB is the standard target. 15 to 25 dB alongside a capped sync is a short, clean line coasting. Under 6 dB, or sagging at night, predicts resyncs before they show up in the stability flag.

Stability. nbn's own historical numbers: an average of about 2.4 resyncs a day was classed "stable", and lines with up to 5 dropouts a day were classed "risky" yet treated as acceptable. Use that to calibrate: a handful of drops a week is normal life on copper; multiple drops a day, every day, is an instability case you should push, starting with a Stability Profile and a 48 hour retest.

## DLM and the Physical Profile string

nbn runs Dynamic Line Management on FTTN/B. When a line drops or errors too much, the profile is moved toward stability: higher target noise margin (6 to 9 to 12 dB), interleaving and/or retransmission (G.INP). Each step costs speed (and interleaving adds a few ms of latency) in exchange for holding sync. A stability profile applied via Carbon does the same thing on request, and Aussie's workflow expects it: apply, hold for 48 hours, rerun Line State, escalate to nbn only if the line still is not stable. Seeing "Standard 6dB" in the profile is therefore itself diagnostic: the line has a clean enough history that nobody, human or DLM, has had to intervene.

## Co-Existence, and why it matters less than it sounds

"(Co-Existence)" means legacy services (ADSL2+ from the exchange, special services) still share copper in that distribution area, so the node runs restricted spectrum and downstream power back-off to avoid interfering with them. It lowers attainable rates, mostly on longer loops, and it ends only when nbn is satisfied the legacy services are gone; plenty of areas never formally exit. On a 49 m loop the effect is negligible. On a 600 m loop it can be the difference between holding 50 and not.

## What "meets the NBN spec" actually means

This is the part Aussie's techs tend to wave at without explaining. The floors nbn actually commits to are much lower than the plan tier:

* During co-existence, nbn's committed peak information rate objective on FTTN is 12/1 Mbps (25/5 on FTTB). nbn has disputed that this is a "cap", but it is the floor their fault teams work to.
* After co-existence, the objective rises to 25/5, aligning with the statutory requirement of 25 Mbps peak downstream.

So when a tech says a poor line "meets spec", they usually mean it clears 12/1 or 25/5, not that it can do the customer's 100/40 plan. Arguing the plan tier with nbn is mostly futile. The plan-tier remedy sits with the RSP instead: under the ACCC's broadband speed claims guidance, RSPs must check the line's maximum attainable speed after activation, tell the customer if the line cannot reach the plan tier, and offer a remedy (move to a lower tier with a refund, or exit). The Telstra and Optus undertakings, where tens of thousands of FTTN customers were compensated, are the precedent.

When nbn will genuinely act on a fault:

* The line is UNSTABLE (or dropping repeatedly) and a stability profile has not fixed it.
* The attainable rate has degraded materially against the line's own history (always screenshot baselines into the ticket).
* The line is below the co-existence/post-co-existence floors above.
* Physical-layer evidence: noise margin collapsing, errors, sync far below attainable with no cap explanation.

## The Loopback test

The loopback sends a small amount of test data from the RSP/nbn side to the premises equipment and back, in both directions. On FTTN/B the modem must be in sync, and the loop exercises the layer 2 path across the POI, the node, the copper, and the CPE.

Passed means exactly one thing: at test time, data flowed both ways. It says nothing about speed, noise, or whether the service drops every evening. Intermittent faults routinely pass loopbacks.

Failed while Line State shows the port Up and in sync is a meaningful contradiction: power cycle the nbn side equipment and CPE, rerun, and escalate if it still fails. Expect the test to briefly interrupt traffic (a run takes a minute or two, as in your example's Created/Completed timestamps).

## 60 second triage

1. Operational Status Up? If not, it is a no-sync problem (CPE, premises wiring, port), not a speed problem.
2. Service Stability STABLE? If not: stability profile, 48 hours, retest, then escalate.
3. Physical Profile still "Standard 6dB"? A stability/high-margin profile means the line has been misbehaving even if it looks fine right now.
4. Attainable vs tier: at or above the cap, marginal, or below tier?
5. Sync vs cap (~tier + 10%): at cap means full plan speed is available on the copper.
6. Noise margin vs target: big surplus good, at target fine, under 6 dB or swinging is trouble brewing.
7. All clean but the customer is slow? The DSL segment is exonerated: look at Wi-Fi, router, cabling past the first socket, the test device, VPN overlays, or congestion, and test wired at the modem.

## Worked example (the healthy one)

| Field | Value | Verdict |
|---|---|---|
| Operational Status / Stability | Up, STABLE | Port in sync, clean recent history |
| DSL Mode | VDSL2 | Correct for FTTN |
| Estimated Distance to Node | 49 m | About as good as FTTN gets |
| Physical Profile | 100/40 Standard 6dB (Co-Existence) | Default profile, no DLM intervention ever needed. Co-existence area, irrelevant at 49 m |
| Attainable Rate | 144.0 / 50.4 | Line could hold ~144/50; far above the 100/40 tier. Big headroom |
| Current Sync Rate | 107.7 / 44.2 | At the provisioning cap (100/40 caps around 110/44). Full 100/40 is available at layer 3 after overheads |
| Loop Attenuation | N/A / 1.0 dB | 1 dB is a near-zero loss loop, consistent with 49 m. N/A downstream is a portal quirk |
| Noise Margin | 17.5 / 21.1 dB | Triple the 6 dB target while synced at the cap. Huge headroom, extremely stable line |
| Loopback | Passed in ~2 min | Layer 2 path verified end to end |

Verdict: textbook healthy. Nothing here is worth a ticket to nbn or a question to Aussie. If the end user still reports slowness, the copper is exonerated: investigate CPE, Wi-Fi, LAN, the measuring device, or upstream of the access network.

## Escalation phrasing that works with Aussie support

* Instability: "Line State shows UNSTABLE with N resyncs; please apply a stability profile. We will retest in 48 hours and want an nbn instability fault raised if it has not returned to STABLE."
* Line cannot do the tier: "Attainable is 62/18 on a 100/40 service. The copper cannot support the tier, so please run the speed review process: we want the ACCC remedy options (tier downgrade and refund) and an nbn investigation only if this is a degradation from previous attainable figures."
* Degradation: "Attainable was 105/42 on [date] (attached) and is now 71/30 with the same profile. That is a physical degradation, please lodge with nbn."
* Clean line, slow customer: do not ask for an nbn ticket. Note the capped sync and margins in your PSA ticket and pivot to the premises/LAN.

## Good practice for MSP fleets

Snapshot Line State into the client's ticket or documentation at handover (the baseline), after any nbn work, and whenever a fault is suspected. Degradation against a baseline is the single most persuasive artefact you can hand Aussie, because it converts "customer says it is slow" into "the access line measurably changed". For suspected noise/interference, capture one business-hours test and one evening test and compare margins.

## Sources

* [Aussie Broadband: Service test options in MyAussie](https://www.aussiebroadband.com.au/help-centre/internet/service-test-options-available-in-myaussie/) (test behaviours, stability profile workflow, escalation criteria)
* [Hosted Network KB: NBN self-diagnostic tools](https://kb.hostednetwork.com.au/support/services/connectivity/nbn-tc4/troubleshooting/nbn-self-diagnostic-tool) (line state and loopback definitions, service-impacting notes)
* [AusNOG: NBN VDSL speeds, line sync and max throughput](https://lists.ausnog.net/pipermail/ausnog/2017-March/038400.html) (sync caps ~10% above tier, attainable vs sync)
* [jxeeno: FTTN limited to 12/1 during transition](https://blog.jxeeno.com/nbn-fttn-limited-to-121-mbps-during-transition/) and [the follow-up clarification](https://blog.jxeeno.com/incorrect-documentation-fttn-speeds-will-not-be-121-during-transition/) (co-existence commitments, DPBO)
* [Link list discussion of nbn dropout acceptability](https://mailman.anu.edu.au/pipermail/link/2016-March/035630.html) (2.4 resyncs/day "stable", 5/day "risky yet acceptable")
* [DrayTek FAQ: SNR and loop attenuation bands](https://faq.draytek.com.au/2008/03/14/what-do-the-snr-and-loop-att-values-indicate/) (generic DSL interpretation bands)
* [ACCC: Telstra compensates 42,000 customers for slow NBN speeds](https://www.accc.gov.au/media-release/telstra-offers-to-compensate-42000-customers-for-slow-nbn-speeds) (attainable-below-tier remedy precedent)
* Further reading (Whirlpool threads, not fetchable programmatically but worth a read logged in): [Line State Test on MyAussie](https://forums.whirlpool.net.au/archive/9xkxmk23), [What is a loopback test](https://forums.whirlpool.net.au/archive/3pxjwwn0), [Stability profiles: how do they work](https://forums.whirlpool.net.au/archive/3vypy809), [Post your FTTN/VDSL2 modem stats](https://forums.whirlpool.net.au/archive/2479157)

Notes on confidence: the sync-cap figures (~110/44 for 100/40, ~55/22 for 50/20) and distance heuristics are well-worn community/operator numbers rather than published nbn constants, and nbn has never formally published DLM thresholds. Treat them as calibration, not gospel. The co-existence 12/1 commitment comes from WBA-era documentation and nbn has publicly quibbled the word "cap" while standing by the figure as the committed objective.
