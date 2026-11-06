# OpenAI proxy request controls

`index.ts` supplies the shared `verifyUser` helper to `createHandler`. The
handler uses verified user IDs for user quotas. The optional anonymous bridge
applies a separate policy to callers presenting the configured Supabase anon
key. The behavior tests inject local authentication, upstream, clock,
environment, and log mocks.

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
- Authentication and quota checks happen before the handler reads the request
  body. Admitted POST attempts consume quota before body validation. Invalid
  requests and upstream failures therefore still consume quota.
- Native requests without Origin are accepted. Browser requests and preflights
  require an exact configured Origin. Wildcard and `null` origins are not
  enabled.
- Upstream requests time out with 504 `upstream_timeout`. Other upstream HTTP
  error statuses are preserved with a generic error and request ID. Error bodies
  and exceptions are suppressed. Successful upstream bodies pass through.

## Environment names and defaults

No settings are changed by this implementation.

| Name                                  | Default / purpose                                                                      |
| ------------------------------------- | -------------------------------------------------------------------------------------- |
| `OPENAI_PROXY_MAX_BODY_BYTES`         | `65536`                                                                                |
| `OPENAI_PROXY_ALLOWED_MODELS`         | `gpt-4o-mini`, comma separated                                                         |
| `OPENAI_PROXY_MODEL_ENFORCE`          | `false`; only the value `true` enables rejection                                       |
| `OPENAI_PROXY_MAX_TOKENS`             | `1500`, used for the default and cap                                                   |
| `OPENAI_PROXY_MAX_MESSAGES`           | `20`                                                                                   |
| `OPENAI_PROXY_RATE_LIMIT_PER_MINUTE`  | `20`                                                                                   |
| `OPENAI_PROXY_RATE_LIMIT_PER_DAY`     | `300`                                                                                  |
| `OPENAI_PROXY_RATE_LIMIT_MAX_USERS`   | `10000` active user entries per instance                                               |
| `OPENAI_PROXY_ALLOW_ANON`             | `false`; only the exact value `true` enables the temporary bridge                      |
| `OPENAI_PROXY_ANON_PER_MINUTE`        | `5` per IP                                                                             |
| `OPENAI_PROXY_ANON_PER_DAY`           | `60` per IP                                                                            |
| `OPENAI_PROXY_ANON_GLOBAL_PER_MINUTE` | `30` across anonymous callers in one instance                                          |
| `OPENAI_PROXY_ANON_GLOBAL_PER_DAY`    | `600` across anonymous callers in one instance                                         |
| `OPENAI_PROXY_UPSTREAM_TIMEOUT_MS`    | `30000` milliseconds                                                                   |
| `OPENAI_PROXY_ALLOWED_ORIGINS`        | Empty; comma separated exact HTTP(S) origins                                           |
| `OPENAI_API_KEY`                      | Existing upstream credential                                                           |
| `OPENAI_BASE_URL`                     | Existing optional base URL override; existing Hermes local key fallback is preserved   |
| `SUPABASE_URL`                        | Existing authentication helper setting                                                 |
| `SUPABASE_SERVICE_ROLE_KEY`           | Existing authentication helper setting                                                 |
| `SUPABASE_ANON_KEY`                   | Existing Supabase public key. A nonempty value is required to admit anonymous callers. |

Numeric controls require positive safe integers. The timeout also has a maximum
of 2,147,483,647 milliseconds. Invalid settings use the listed defaults. A model
identifier is bounded to 128 ASCII identifier characters before it can be
logged. For a verified user, an out-of-list identifier is forwarded and recorded
as `model_not_allowed_log_only` while enforcement is disabled. Logs record the
outcome status, caller type (`user` or `anon`) and SHA-256 hash of the user ID
or IP bucket for an identified caller, the validated model, token aggregates,
and request ID. They exclude raw IPs, user IDs, credentials, and prompts.

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

Each caller's timestamp array is bounded by the daily request cap. Sweeps remove
expired entries. The user ledger has a configured capacity, and the separate
anonymous IP ledger has a capacity of 10,000. When either ledger is full, a new
caller receives 429 with Retry-After. Active entries retain their quota history.

## Temporary anonymous bridge

Set `OPENAI_PROXY_ALLOW_ANON=true` only while released clients still need to
call the proxy with the anon key. The handler first calls `verifyUser`. A 401
`invalid_token` response permits the anonymous path only if the bearer token
exactly matches `SUPABASE_ANON_KEY`. Anonymous callers must use an allowlisted
model even when `OPENAI_PROXY_MODEL_ENFORCE` is disabled. Confirm the released
clients' model configuration is on the list before enabling the bridge.

Anonymous calls use both an IP quota and an instance-wide anonymous quota,
independent of user quotas. The IP bucket uses `cf-connecting-ip`, then the
first value in `x-forwarded-for`, then the fixed `unknown` bucket. Callers can
spoof IP headers. The instance-wide anonymous quota remains the final ceiling
even when callers rotate header values. Both anonymous ledgers live in memory,
reset when the function instance restarts, and are independent across instances.

After the app version that sends user tokens has rolled out, set
`OPENAI_PROXY_ALLOW_ANON=false` or remove it. Calls that only send the anon key
will then receive 401.

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

The previously observed production v17 body lacks the repository's user
authentication gate. Review client impact before deployment and preserve the
prior deployed v17 for rollback.
