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
2. Put its client id in `web/.env` as `INTERVALS_CLIENT_ID=...`.
3. With Cloudflare credentials available to Alchemy, run `npx pnpm@10 deploy`.

`npx pnpm@10 dev` runs everything locally in workerd.

Cadencia iOS signs in through `/auth/intervals/start?client=ios`, receives a
one-minute handoff at `cadencia://auth/callback?handoff=…`, and exchanges it at
`POST /auth/exchange` for a session token it sends as `Authorization: Bearer`.
