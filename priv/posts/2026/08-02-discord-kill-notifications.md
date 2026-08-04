%{
title: "New Feature: Discord Kill Notifications",
author: "Wanderer Team",
cover_image_uri: "/images/news/08-02-discord-kill-notifications/cover.png",
tags: ~w(discord notifications kills map settings guide),
description: "Post kills from your map straight into a Discord channel. Set a webhook once, filter to wormhole space, exclude the systems you don't care about."
}

---

# Discord Kill Notifications

Your chain is already telling you where the fights are — the Kills widget shows
every killmail in the systems on your map. The catch is that somebody has to be
looking at it. If the map is on a second monitor nobody is watching, a hostile
gang rolling into your home hole looks exactly like an empty screen.

So we added a direct line out: **Discord kill notifications**. Point your map at
a Discord webhook and kills in your chain get posted into the channel your
corp is already sitting in.

## Setting it up

Open **Map settings → Notifications**. The tab lives inside the map's settings
page, so it is available to whoever can administer the map — in practice the map
owner and anyone granted admin rights over it.

1. **Create a webhook in Discord.** In your Discord server, open
   *Server Settings → Integrations → Webhooks*, create one, pick the channel it
   should post to, and copy the webhook URL.
2. **Paste the URL** into the *Discord webhook URL (system channel)* field on
   the Notifications tab and hit **Save**.
3. **Optionally add a character channel.** The *Character channel (optional)*
   section takes a second webhook. Kills involving your own pilots go there
   instead, so you can keep them out of the chain-intel channel. By default
   "your own pilots" means the map's tracked characters; the **Corporation
   filter** below the field changes that. If no character channel is
   configured, these kills simply stay in the system channel — the split is
   opt-in.
4. **Send a test message** to confirm the wiring before you rely on it. The
   button is right there under the form.

That is the whole setup. From that point on, kills detected in systems on the
map are formatted and pushed to the channel.

## What a notification looks like

Each kill arrives as a Discord embed:

- **Title** — who lost what ("Some Pilot lost a Loki"), linking straight to the
  killmail on zKillboard.
- **System**, **Value**, **Final blow**, **Corp**, and **Alliance** fields. The
  final-blow field shows the number of other attackers, so `Some Pilot (+11)`
  tells you at a glance whether this was a solo gank or a fleet.
- A **ship render** thumbnail and the victim's corp ticker in the footer.

Fields that we have no data for are simply left out rather than posted as
"Unknown", so the embed stays readable.

When a burst of kills lands at once — a fleet fight, a gate camp working through
a convoy — the embeds are batched into as few messages as Discord allows, and a
very large batch is capped with a "…and N more kills not shown." line rather
than flooding your channel with a hundred separate posts.

## Filters

Two controls, both on the Notifications tab:

- **Only wormhole kills** (on by default). Restricts notifications to J-space,
  including Thera, shattered systems, and the drifter holes. Turn it off if you
  want kills from every system on the map, k-space included.
- **Excluded systems.** Search a system by name and add it to the list. Kills
  there are skipped. This is the one to use for your home system if you would
  rather not get a ping every time somebody shoots a structure, or for a
  highway system that generates constant noise.

There is also an **Enabled** checkbox, so you can mute the feed without
throwing away the webhook and its filter list.

**Both filters have a deliberate carve-out:** they do not apply to a kill that
involves one of your own pilots. A kill involving your people is interesting
wherever it happened, so it is still delivered even from an excluded system, and
even from k-space with *Only wormhole kills* left on. Those kills go to the
character channel when one is configured, and to the system channel otherwise.
If you want a system genuinely silent, the **Enabled** checkbox is the control
that covers everything.

**One thing worth being clear about:** these filters are *not* the same as the
Kills widget filters. The widget's filters are per-user and only change what
*you* see in the map UI. The Discord filters are per-map and server-side — they
apply to everyone in the channel. The two look similar and are deliberately
kept separate.

## Corporation filter

Under the character channel there is a **Corporation filter**. It answers one
question: *who is the character channel for?*

- **Leave it empty** and the answer is "the characters tracked on this map."
  That is the default and it is what the feature did before this setting
  existed.
- **Add one or more corporations** and the answer becomes "members of these
  corporations" — *instead of* the map's tracked characters, not in addition to
  them.

That replacement is the point. If your map tracks a mixed group of scouts and
alts but the channel is meant to be your corp's kill feed, setting the filter
takes the untracked-corp pilots' kills out of it. Those kills are not lost —
they fall through to the normal system rules and land in the system channel if
they pass the filters there.

The carve-out above follows whichever criterion is active: with a corporation
filter set, kills involving those corporations bypass the excluded-system and
wormhole-only filters, and kills involving map-tracked characters no longer do.

Matching looks at the victim first, then the attackers, and at *corporation*
membership on both sides — so a corp member on either end of a killmail counts,
whether or not that character is on the map.

## Where a kill goes

The full routing table, in order. "Ours" means the kill matched the active
criterion — a map-tracked character, or a filtered corporation if the
Corporation filter is set.

1. Not ours, and the system is on the **excluded systems** list → dropped.
2. Not ours, *Only wormhole kills* is on, and the system is k-space → dropped.
3. Ours → the **character channel**, falling back to the system channel if no
   character webhook is configured.
4. Anything else → the **system channel**.

There is a third possibility besides "ours" and "not ours": *undetermined*. A
killmail can arrive without attacker information, or the map's tracked-character
list can be briefly unreadable after a restart. In that case the map genuinely
does not know whether the kill is yours.

Undetermined kills are treated as neither. They do **not** get dropped by rules
1 and 2 — those filters are only earned by a positive "this kill is not ours",
and treating a missing answer as a "no" would mean a brief hiccup silently
swallowed every k-space kill with the default settings. And they do **not** go
to the character channel either, because that channel is supposed to mean "these
are ours". They go to the system channel, and the server logs a warning so the
cause is visible rather than inferred from a quiet channel.

## About the webhook URL

A Discord webhook URL is a credential: anyone holding it can post to your
channel. So we treat it like one.

- It is **stored encrypted** in the database.
- After you save it, it is never displayed in full again — the settings tab
  shows a masked hint like `.../123456/AbCd••••`.
- To point the map at a different channel, click **Replace** and paste the new
  URL. There is no way to read the old one back out of the UI.

If a webhook is deleted on the Discord side, Discord answers with a 404 and that
destination is disabled automatically — no point retrying a channel that no
longer exists. Each destination carries its own enabled flag and health state,
so disabling the character channel this way leaves the system channel posting
normally, and vice versa. Other transient errors (rate limits, brief outages)
are retried with backoff for a bounded number of attempts, and only a sustained
run of failures will disable a destination. Those retries all happen inside the
one delivery attempt — once the attempts are exhausted, the message is dropped
rather than re-queued, which is what keeps delivery at most once (see *Known
limits* below).

## Self-hosting notes

Wanderer CE runs this behind the same switch as the rest of the outbound events
system:

```bash
export WANDERER_WEBHOOKS_ENABLED="true"
```

With it off, the Notifications tab still renders but "Send test message" will
tell you notifications are disabled on this server.

Delivery uses its own isolated connection pool, so a slow Discord cannot back up
the rest of the application. If you run a large instance with many maps sending
notifications, you can size that pool:

```bash
export WANDERER_DISCORD_POOL_SIZE="10"   # default
```

## Known limits

Worth knowing before you wire it into an intel channel:

- Notifications are **at most once**. If a delivery fails outright, that kill is
  not re-sent later. We would rather drop the occasional kill than double-post
  into a chat channel, and a dropped kill is still visible in the Kills widget
  and on zKillboard.
- Deduplication is in memory, so a restart of the application can let a kill
  that was already posted be posted once more.
- Two channels per map: one for system kills, one for character kills. Splitting
  further than that — a channel per region, per corp, per anything else — is not
  supported yet.

Fly safe. o7
