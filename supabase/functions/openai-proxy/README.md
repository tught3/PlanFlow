# OpenAI proxy S1 local hardening

`index.ts` keeps the existing `verifyUser` authentication helper and supplies it
to `createHandler`. Anonymous keys remain rejected by that helper. No client IP
or decoded JWT fallback is used for quotas. The handler module has injectable
I/O so tests use only local authentication, upstream, clock, environment, and
log mocks.

## Request controls

- Content-Length and bytes read from the request stream are capped. Reading
  stops and the reader is cancelled as soon as the actual byte cap is exceeded.
- Only `model`, normalized text `messages`, `temperature`, `top_p`, output token
  limits, and `response_format` are copied from the request. `n=1` and
  `stream=false` are always added. Message roles are `system`, `developer`,
  `user`, and `assistant`; multimodal content and tool messages are rejected.
  Unapproved nested message fields are removed.
- Output limits are positive integers. Each supplied token field is clamped; if
  neither is supplied, `max_tokens` is inserted with the configured cap.
- Authenticated POST attempts consume quota before body validation and upstream
  calls. Invalid requests and upstream failures therefore still consume quota.
- Native requests without Origin are accepted. Browser requests and preflights
  require an exact configured Origin. Wildcard and `null` origins are not
  enabled.
- Upstream error status is preserved with a generic error and request ID. Error
  bodies, exceptions, credential names, prompt text, and raw user IDs are not
  returned or logged. Successful upstream bodies remain unchanged.

## Environment names and defaults

No settings are changed by this implementation.

| Name                                 | Default / purpose                                                                    |
| ------------------------------------ | ------------------------------------------------------------------------------------ |
| `OPENAI_PROXY_MAX_BODY_BYTES`        | `65536`                                                                              |
| `OPENAI_PROXY_ALLOWED_MODELS`        | `gpt-4o-mini`, comma separated                                                       |
| `OPENAI_PROXY_MODEL_ENFORCE`         | `false`; only the value `true` enables rejection                                     |
| `OPENAI_PROXY_MAX_TOKENS`            | `1500`, used for the default and cap                                                 |
| `OPENAI_PROXY_MAX_MESSAGES`          | `20`                                                                                 |
| `OPENAI_PROXY_RATE_LIMIT_PER_MINUTE` | `20`                                                                                 |
| `OPENAI_PROXY_RATE_LIMIT_PER_DAY`    | `300`                                                                                |
| `OPENAI_PROXY_RATE_LIMIT_MAX_USERS`  | `10000` active user entries per instance                                             |
| `OPENAI_PROXY_ALLOWED_ORIGINS`       | Empty; comma separated exact HTTP(S) origins                                         |
| `OPENAI_API_KEY`                     | Existing upstream credential                                                         |
| `OPENAI_BASE_URL`                    | Existing optional base URL override; existing Hermes local key fallback is preserved |
| `SUPABASE_URL`                       | Existing authentication helper setting                                               |
| `SUPABASE_SERVICE_ROLE_KEY`          | Existing authentication helper setting                                               |

Numeric controls require positive safe integers; invalid settings use the listed
defaults. The model identifier is bounded to 128 ASCII identifier characters
before it can be logged. An out-of-list identifier is forwarded and recorded as
`model_not_allowed_log_only` while enforcement is disabled. The log records the
actual outcome status, a SHA-256 user ID hash, validated model, token
aggregates, and request ID only.

The Firebase Remote Config production `gpt_model` value is unverified. The
`gpt-4o-mini` default comes from the repository's Remote Config default; no
remote value is inferred. Out-of-list models can still cost more while
enforcement is disabled. Verify the production value and configure the list
before explicitly enabling enforcement.

## Quota limits

The sliding minute and day windows are in memory within one function instance.
Restarts clear counters, and multiple instances do not share a global quota.
Durable global accounting is a follow-up. Check and consume run synchronously so
parallel requests within the same instance cannot overrun the quota.

Each user's timestamp array is bounded by the daily request cap. Expired users
are removed during sweeps. The active-user map is bounded by its configured
capacity; at capacity, new users receive 429 with Retry-After rather than
evicting active users and resetting their quotas.

## Local verification

```text
deno test --deny-net supabase/functions/openai-proxy/handler.test.ts
deno fmt --check supabase/functions/openai-proxy
deno lint supabase/functions/openai-proxy
deno check --deny-import supabase/functions/openai-proxy/index.ts
```

The behavior tests import only the local handler, inject all I/O, and have no
network, environment, or filesystem permissions. Production entrypoint checking
denies remote imports; missing or disallowed external dependencies are reported
without downloading them. No OpenAI or Supabase API request is needed.

Deploying repository source also deploys its existing user authentication gate,
which is absent from the previously observed production v17 body. Anonymous
PlanFlow or NexusFlow callers will receive 401. Client impact must be reviewed
before any separately approved deployment. The prior deployed v17 should be
selected in Supabase for rollback; this folder does not invent a deployable v17
body from its summary.
