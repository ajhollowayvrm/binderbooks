# The BinderBooks AWS account

**This is a personal AWS account.** It is not an employer account. It shares no credentials, no
process and no infrastructure with any work estate. Nothing in this directory is subject to a work
review process, pipeline gate or ticket.

Treat that as a rule about **credentials** first, because that is where the two can actually collide.

## Always use a named profile

Never put these credentials in the **default** profile. A default profile is what an unrelated
command picks up when it names no profile at all, and that is the failure mode worth designing out —
a work command reaching this account, or a BinderBooks command reaching a work account.

Set it up once:

```sh
aws configure --profile personal      # region: us-west-2
```

Then name the profile on every call:

```sh
aws sts get-caller-identity --profile personal
```

If you would rather not repeat the flag, export it for the shell you are working in — but never put
it in a shared shell profile, because that makes it the silent default again:

```sh
export AWS_PROFILE=personal
```

## What lives in this account

| Resource | Detail |
|---|---|
| HTTP API | `j18dixq7ei`, `us-west-2` — the `binderbooks-sync` API Gateway |
| Lambda | `binderbooks-sync` — holds `SYNC_TOKEN`, `PPT_KEY` (all card data) and the Anthropic API key |
| DynamoDB | The ledger table behind that Lambda — also the card-data cache (`set:*`, `sets:*`, `hist:*` items) |

Secrets live only on the Lambda, never in this repo. The app is a static bundle, so anything shipped
to the client is public.

## Deploying

From macOS or Linux:

```bash
cd aws
./deploy.sh                              # code only
./deploy.sh --ppt-key "ppt_..."          # also set the PPT key all card data needs
./deploy.sh --anthropic-key "sk-ant-..." # also set the key /identify needs
```

`deploy.ps1` is the Windows twin of the same thing:

```powershell
cd aws
.\deploy.ps1 -AnthropicKey "sk-ant-..."
```

**Deploy after every change to `index.mjs`.** Nothing does it automatically, and
a Lambda running last week's code fails in ways that look like an API problem
rather than an undeployed fix — which is how the "stop comping the wrong card"
change sat unshipped while `/graded` kept returning the wrong card's prices.

The web build is the half that *does* ship by itself, on every push to `main`,
which makes the gap between the two its own hazard. The client's rate-limit
wording reads a `kind` field that only a deployed Lambda sends; until this is
deployed, a new bundle keeps calling every 429 the daily budget — which is
exactly the bug it was written to fix.

## CORS

`AllowOrigins` is `["*"]`, and that is deliberate.

It used to name `https://ajhollowayvrm.github.io` and `http://localhost:5173` explicitly. The iOS
shell broke that model: its origin is `binderbooks://local`, and API Gateway **refuses** a
non-http(s) origin outright —

```
BadRequestException: Invalid format for origin binderbooks://local
```

So the shell could never be added to an explicit list. The choice was to widen the list or to proxy
every API call through native code. Widening won, because the allowlist was not protecting anything:

- **Every route needs `x-sync-token`.** Since the card-data routes moved to pokemonpricetracker
  (whose credits are metered), nothing on this API answers without the token — a request that CORS
  would have blocked fails on auth anyway. A hostile page gains nothing from being allowed to send
  a request, because it cannot read the token — that lives in `localStorage` under a different
  origin, which the same-origin policy keeps out of its reach.
- **CORS only restrains browser JavaScript.** curl never cared. It was never the control here.

The Lambda **fails closed** when `SYNC_TOKEN` is not set. `String(undefined)` is
the nine-character string `"undefined"`, so an unset variable used to
authenticate any request that sent `x-sync-token: undefined` — and
`update-function-configuration` replaces the whole environment, which is exactly
how a deploy drops a variable. A function with no token, an empty token, or the
literal string `"undefined"` or `"null"` now rejects every request.

The test is presence, not a minimum length, and that is deliberate: a length
rule would reject whatever token is live today and lock every device out of the
ledger the moment it deployed. Pick a long token when you rotate one — nothing
here enforces it, because failing open was the bug and failing shut on a valid
token would be a worse one.

The real access control is the token. Treat it that way: if it leaks, rotate `SYNC_TOKEN` on the
Lambda and repaste it on each device. Do not reach for the CORS list as a security control, because
it never was one.

```sh
aws apigatewayv2 get-api --api-id j18dixq7ei --profile personal --query 'CorsConfiguration'
```

```sh
aws apigatewayv2 update-api --api-id j18dixq7ei --region us-west-2 --profile personal \
  --cors-configuration '{
    "AllowOrigins": ["*"],
    "AllowHeaders": ["content-type", "x-sync-token"],
    "AllowMethods": ["GET", "POST", "PUT"],
    "MaxAge": 86400
  }'
```

`update-api` **replaces** the whole CORS block — it does not merge. If you ever narrow this again,
every origin you want to keep must appear in the same command, and the iOS app will stop working the
moment the list stops being `*`. Check each client after any change:

```sh
curl -s -D - -X OPTIONS -H "Origin: binderbooks://local" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type,x-sync-token" \
  https://j18dixq7ei.execute-api.us-west-2.amazonaws.com/ -o /dev/null | grep -i access-control
```

A correct answer echoes `access-control-allow-origin` for the origin you sent. No such header means
that client is blocked. There are three clients to check now, not one: `binderbooks://local` (the
iOS app), `https://ajhollowayvrm.github.io` (the hosted web build, live again since Pages was
switched back on) and `http://localhost:5173` (the dev server).
