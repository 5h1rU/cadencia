# Cadencia web

The web app and backend of Cadencia: two domain models built with
[Alchemy Domain](https://alchemy.run/domain) on Effect, hosted on Cloudflare
Durable Objects, and a [foldkit](https://foldkit.dev) web app.

- **Intervals.icu** is the system of record for activities, wellness,
  declarations and the calendar.
- **Planning** (`packages/planning`) owns each plan's intent and the rules every
  change must pass: availability, the athlete's own limits, and that readiness
  can soften a session but never harden it.
- **Coach** (`packages/coach`) records what the AI interpreted, with its model
  and evidence. The AI runs in Cadencia iOS with the athlete's ChatGPT plan;
  the backend never calls an LLM.
- **Server** (`packages/server`) hosts both models in one Worker, signs athletes
  in with Intervals.icu OAuth, publishes sessions to their Intervals calendar,
  notices changes made there, and serves a plain HTTP API with OpenAPI at
  `/v1/openapi.json` for iOS.
- **Shared packages**: `identity` (who acts and whose data it is), `kernel`
  (the terms both models share: days, plan ids, text, training) and `athlete`
  (what Intervals.icu says about the athlete: evidence, readiness, measures).
- **Web API** (`packages/web-api`) declares, as an Effect `HttpApi`, what the
  Worker serves the web over plain HTTP: the session, signing in with
  Intervals.icu, and the athlete's Intervals data. The server implements it;
  the app calls it with `HttpApiClient`.
- **App** (`packages/app`) shows everything live and writes only what needs no
  AI: moving a session, a day's limit, retiring the plan, accepting or
  dismissing a proposal, and wellness declarations.

## Develop

```sh
npx pnpm@10 install
npx pnpm@10 test        # stories and tests of every package
npx pnpm@10 typecheck
```

## Deploy

1. Register an OAuth app in Intervals.icu with the callback
   `https://<your app origin>/auth/intervals/callback`.
2. In the app's settings, add the webhook URL `https://<api origin>/webhooks/intervals`,
   tick `CALENDAR_UPDATED`, and set a Webhook Secret. Intervals then tells
   Cadencia when an athlete changes their calendar, and Cadencia reads it again.
3. Put the client id, client secret and webhook secret in `web/.env` (see
   `.env.example`).
4. With Cloudflare credentials available to Alchemy, run `npx pnpm@10 deploy`.

The stack keeps its state in Cloudflare (`Cloudflare.state()`), so a deploy
from any machine or from CI keeps the keys that sign sessions and encrypt
Intervals tokens. A deploy that starts from empty state mints new keys: every
session ends and every athlete must connect Intervals again.

Events and views are versioned by their schemas. A view rebuilds itself when
its `version` goes up; an event whose shape changes must still decode its old
shape, unless the stage is destroyed and deployed again.

`npx pnpm@10 dev` runs everything locally in workerd.

Cadencia iOS signs in through `/auth/intervals/start?client=ios`, receives a
one-minute handoff at `cadencia://auth/callback?handoff=…`, and exchanges it at
`POST /auth/exchange` for a session token it sends as `Authorization: Bearer`.
