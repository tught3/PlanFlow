import { describe, expect, it } from "vitest";
import { maskPII, sanitizeForLog } from "./logger";

describe("maskPII", () => {
  it("masks a non-empty string value", () => {
    expect(maskPII("김철수")).toBe("[REDACTED]");
  });

  it("masks null/undefined without throwing", () => {
    expect(maskPII(null)).toBe("[REDACTED]");
    expect(maskPII(undefined)).toBe("[REDACTED]");
  });

  it("never returns the original value verbatim", () => {
    // banned-ok: PII 마스킹 검증용 가짜 전화번호 리터럴, 실제 비밀값 아님
    const secret = "010-1234-5678";
    expect(maskPII(secret)).not.toBe(secret);
  });
});

describe("sanitizeForLog", () => {
  it("masks title, memo, and participants fields on an event object", () => {
    const event = {
      id: "evt_1",
      title: "치과 예약",
      memo: "강남역 3번 출구 치과, 개인 메모",
      participants: ["김철수", "이영희"],
      startAt: "2026-08-05T10:00:00Z",
    };

    const sanitized = sanitizeForLog(event) as Record<string, unknown>;

    expect(sanitized.title).toBe("[REDACTED]");
    expect(sanitized.memo).toBe("[REDACTED]");
    expect(sanitized.participants).toBe("[REDACTED]");
    // Non-PII fields must pass through untouched.
    expect(sanitized.id).toBe("evt_1");
    expect(sanitized.startAt).toBe("2026-08-05T10:00:00Z");
  });

  it("masks PII fields nested inside arrays and objects", () => {
    const payload = {
      events: [
        { title: "회의", memo: "비공개 안건" },
        { title: "생일파티", memo: "선물 리스트" },
      ],
    };

    const sanitized = sanitizeForLog(payload) as {
      events: Array<Record<string, unknown>>;
    };

    for (const evt of sanitized.events) {
      expect(evt.title).toBe("[REDACTED]");
      expect(evt.memo).toBe("[REDACTED]");
    }
  });

  it("does not mask unrelated fields", () => {
    const data = { id: 1, count: 5, isActive: true };
    expect(sanitizeForLog(data)).toEqual(data);
  });

  it("handles primitives and null gracefully", () => {
    expect(sanitizeForLog("plain string")).toBe("plain string");
    expect(sanitizeForLog(null)).toBe(null);
    expect(sanitizeForLog(42)).toBe(42);
  });
});
