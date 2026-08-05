/**
 * logger.ts
 *
 * Minimal logging helpers for uncaught exceptions and failed API calls,
 * with a mandatory PII-masking step before anything is written to the
 * console. Never log raw event objects (title/memo/participants/location
 * etc.) — always route them through `sanitizeForLog` first.
 */

/** Field names treated as PII and masked wherever they appear. */
const PII_FIELD_NAMES = new Set([
  "title",
  "memo",
  "description",
  "notes",
  "participants",
  "attendees",
  "location",
  "address",
  "phone",
  "phoneNumber",
  "email",
  "name",
  "username",
]);

const MASK_PLACEHOLDER = "[REDACTED]";

/**
 * Masks a single PII string value. Keeps the function pure and reusable so
 * callers can mask individual fields without building a full object.
 */
export function maskPII(value: unknown): string {
  if (value === null || value === undefined) return MASK_PLACEHOLDER;
  const str = typeof value === "string" ? value : String(value);
  if (str.length === 0) return MASK_PLACEHOLDER;
  return MASK_PLACEHOLDER;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype
  );
}

/**
 * Recursively walks an object/array and masks any field whose key matches
 * a known PII field name (case-insensitive). Non-PII fields are preserved
 * as-is. Safe to call on arbitrary event objects before logging.
 */
export function sanitizeForLog(input: unknown, depth = 0): unknown {
  // Guard against pathological/circular-ish structures.
  if (depth > 8) return "[TRUNCATED]";

  if (Array.isArray(input)) {
    return input.map((item) => sanitizeForLog(item, depth + 1));
  }

  if (isPlainObject(input)) {
    const result: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(input)) {
      if (PII_FIELD_NAMES.has(key.toLowerCase())) {
        result[key] = maskPII(value);
      } else if (isPlainObject(value) || Array.isArray(value)) {
        result[key] = sanitizeForLog(value, depth + 1);
      } else {
        result[key] = value;
      }
    }
    return result;
  }

  return input;
}

/**
 * Logs an unhandled/uncaught exception. Any `context` payload is sanitized
 * before it is passed to console.error — never log the raw error context.
 */
export function logException(error: unknown, context?: unknown): void {
  const safeContext = context === undefined ? undefined : sanitizeForLog(context);
  const message = error instanceof Error ? error.message : String(error);
  const stack = error instanceof Error ? error.stack : undefined;
  // eslint-disable-next-line no-console
  console.error("[exception]", message, { stack, context: safeContext });
}

/**
 * Logs a failed API call. `requestPayload`/`responseBody` are sanitized
 * before logging so PII in request/response bodies never reaches the
 * console or any downstream log sink.
 */
export function logApiFailure(params: {
  url: string;
  method?: string;
  status?: number;
  requestPayload?: unknown;
  responseBody?: unknown;
  error?: unknown;
}): void {
  const { url, method, status, requestPayload, responseBody, error } = params;
  // eslint-disable-next-line no-console
  console.error("[api-failure]", {
    url,
    method,
    status,
    requestPayload: requestPayload === undefined ? undefined : sanitizeForLog(requestPayload),
    responseBody: responseBody === undefined ? undefined : sanitizeForLog(responseBody),
    error: error instanceof Error ? error.message : error,
  });
}

/**
 * Installs global handlers for uncaught exceptions and unhandled promise
 * rejections so nothing escapes without at least a sanitized log line.
 * Safe to call multiple times (browser will just add multiple listeners);
 * callers should call this once during app bootstrap.
 */
export function installGlobalErrorHandlers(): void {
  if (typeof window === "undefined") return;
  window.addEventListener("error", (event) => {
    logException(event.error ?? event.message);
  });
  window.addEventListener("unhandledrejection", (event) => {
    logException(event.reason);
  });
}
