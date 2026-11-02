import { describe, expect, test } from "vitest";
import { load } from "./load";

const F = load(() => import("../src/format"));

describe("number formats", () => {
  test("are made once per language and options", () => {
    const Original = Intl.NumberFormat;
    let made = 0;
    class Counted extends Original {
      constructor(...args: ConstructorParameters<typeof Original>) {
        super(...args);
        made += 1;
      }
    }
    Intl.NumberFormat = Counted as typeof Intl.NumberFormat;
    try {
      expect([F.m.fixed(1, 7), F.m.fixed(2, 7)]).toEqual(["1.0000000", "2.0000000"]);
    } finally {
      Intl.NumberFormat = Original;
    }
    expect(made).toBe(1);
  });
});

describe("num", () => {
  test("formats whole numbers with separators", () => {
    expect(F.m.num(1234)).toBe("1,234");
    expect(F.m.num(1.5)).toBe("2");
    expect(F.m.num(0)).toBe("0");
  });

  test("abbreviates large numbers only when short", () => {
    expect(F.m.num(1234567)).toBe("1,234,567");
    expect(F.m.num(1234567, true)).toBe("1.2M");
    expect(F.m.num(9999, true)).toBe("9,999");
    expect(F.m.num(10000, true)).toBe("10K");
    expect(F.m.num(-10000, true)).toBe("-10K");
    expect(F.m.num(-9999, true)).toBe("-9,999");
  });

  test("shows a dash for missing values", () => {
    expect(F.m.num(null)).toBe("–");
    expect(F.m.num(undefined)).toBe("–");
    expect(F.m.num(Number.NaN)).toBe("–");
  });
});

describe("duration", () => {
  test("picks a unit", () => {
    expect(F.m.duration(0)).toBe("0 ms");
    expect(F.m.duration(0.25)).toBe("250 ms");
    expect(F.m.duration(0.9994)).toBe("999 ms");
    expect(F.m.duration(1)).toBe("1.0 s");
    expect(F.m.duration(4.24)).toBe("4.2 s");
    expect(F.m.duration(9.94)).toBe("9.9 s");
    expect(F.m.duration(10)).toBe("10 s");
    expect(F.m.duration(59.4)).toBe("59 s");
    expect(F.m.duration(60)).toBe("1 m 0 s");
    expect(F.m.duration(190)).toBe("3 m 10 s");
    expect(F.m.duration(3599)).toBe("59 m 59 s");
    expect(F.m.duration(3600)).toBe("1 h 0 m");
    expect(F.m.duration(7500)).toBe("2 h 5 m");
    expect(F.m.duration(86399)).toBe("23 h 59 m");
    expect(F.m.duration(86400)).toBe("1 d 0 h");
    expect(F.m.duration(3 * 86400 + 4 * 3600)).toBe("3 d 4 h");
  });

  test("never goes negative", () => {
    expect(F.m.duration(-5)).toBe("0 ms");
  });

  test("shows a dash for missing values", () => {
    expect(F.m.duration(null)).toBe("–");
    expect(F.m.duration(undefined)).toBe("–");
    expect(F.m.duration(Number.NaN)).toBe("–");
  });
});

describe("ms", () => {
  test("formats milliseconds", () => {
    expect(F.m.ms(0.5)).toBe("0.50 ms");
    expect(F.m.ms(1)).toBe("1 ms");
    expect(F.m.ms(120.4)).toBe("120 ms");
    expect(F.m.ms(999.4)).toBe("999 ms");
    expect(F.m.ms(1000)).toBe("1.0 s");
    expect(F.m.ms(1500)).toBe("1.5 s");
  });

  test("shows a dash for missing values", () => {
    expect(F.m.ms(null)).toBe("–");
    expect(F.m.ms(undefined)).toBe("–");
    expect(F.m.ms(Number.NaN)).toBe("–");
  });
});

describe("relative", () => {
  const now = 1_000_000_000_000;
  const at = (seconds: number) => F.m.relative(now + seconds * 1000, now);

  test("treats the last few seconds as now", () => {
    expect(at(0)).toBe("just now");
    expect(at(4.9)).toBe("just now");
    expect(at(-4.9)).toBe("just now");
    expect(at(5)).toBe("in 5 seconds");
    expect(at(-5)).toBe("5 seconds ago");
  });

  test("switches units at each boundary", () => {
    expect(at(59)).toBe("in 59 seconds");
    expect(at(60)).toBe("in 1 minute");
    expect(at(-3599)).toBe("60 minutes ago");
    expect(at(-3600)).toBe("1 hour ago");
    expect(at(-3 * 3600)).toBe("3 hours ago");
    expect(at(86399)).toBe("in 24 hours");
    expect(at(86400)).toBe("tomorrow");
    expect(at(-2 * 86400)).toBe("2 days ago");
    expect(at(86400 * 30)).toBe("next month");
    expect(at(-86400 * 90)).toBe("3 months ago");
    expect(at(86400 * 365)).toBe("next year");
    expect(at(-86400 * 365 * 3)).toBe("3 years ago");
  });

  test("defaults to the current time", () => {
    expect(F.m.relative(Date.now() + 120_000)).toBe("in 2 minutes");
  });

  test("shows a dash for missing values", () => {
    expect(F.m.relative(null)).toBe("–");
    expect(F.m.relative(undefined)).toBe("–");
    expect(F.m.relative(0)).toBe("–");
  });
});

describe("absolute", () => {
  test("pads every field", () => {
    expect(F.m.absolute(Date.UTC(2026, 0, 2, 3, 4, 5))).toBe("2026-01-02 03:04:05");
    expect(F.m.absolute(Date.UTC(2026, 10, 12, 13, 14, 15))).toBe("2026-11-12 13:14:15");
  });

  test("is empty for missing values", () => {
    expect(F.m.absolute(null)).toBe("");
    expect(F.m.absolute(undefined)).toBe("");
    expect(F.m.absolute(0)).toBe("");
  });
});

describe("bytesKb", () => {
  test("picks a unit", () => {
    expect(F.m.bytesKb(512)).toBe("512 KB");
    expect(F.m.bytesKb(1023)).toBe("1023 KB");
    expect(F.m.bytesKb(1024)).toBe("1.0 MB");
    expect(F.m.bytesKb(10239)).toBe("10.0 MB");
    expect(F.m.bytesKb(10240)).toBe("10 MB");
    expect(F.m.bytesKb(204800)).toBe("200 MB");
    expect(F.m.bytesKb(1024 * 1024 - 1)).toBe("1024 MB");
    expect(F.m.bytesKb(1024 * 1024)).toBe("1.0 GB");
    expect(F.m.bytesKb(1.5 * 1024 * 1024)).toBe("1.5 GB");
  });

  test("shows a dash for missing values", () => {
    expect(F.m.bytesKb(0)).toBe("–");
    expect(F.m.bytesKb(null)).toBe("–");
    expect(F.m.bytesKb(undefined)).toBe("–");
  });
});

describe("stampToMs", () => {
  test("parses minute and hour stamps as UTC", () => {
    expect(F.m.stampToMs("202610140930")).toBe(Date.UTC(2026, 9, 14, 9, 30));
    expect(F.m.stampToMs("2026101409")).toBe(Date.UTC(2026, 9, 14, 9));
    expect(F.m.stampToMs("202601011259")).toBe(Date.UTC(2026, 0, 1, 12, 59));
  });
});

describe("argsPreview", () => {
  test("joins JSON-encoded arguments", () => {
    expect(F.m.argsPreview([1, "a", { b: 2 }, null])).toBe('1, "a", {"b":2}, null');
    expect(F.m.argsPreview([])).toBe("");
  });

  test("truncates to the limit", () => {
    expect(F.m.argsPreview(["x".repeat(18)], 20)).toBe(`"${"x".repeat(18)}"`);
    expect(F.m.argsPreview(["x".repeat(19)], 20)).toBe(`"${"x".repeat(18)}…`);
    expect(F.m.argsPreview(["x".repeat(200)])).toHaveLength(120);
  });
});

describe("pct", () => {
  test("is a clamped percentage", () => {
    expect(F.m.pct(1, 4)).toBe(25);
    expect(F.m.pct(5, 4)).toBe(100);
    expect(F.m.pct(-1, 4)).toBe(0);
    expect(F.m.pct(3, 0)).toBe(0);
    expect(F.m.pct(3, -1)).toBe(0);
  });
});

describe("splitIdentity", () => {
  test("splits host, pid and suffix", () => {
    expect(F.m.splitIdentity("web-1.local:4242:ab12")).toEqual({ host: "web-1.local", pid: "4242" });
    expect(F.m.splitIdentity("fe80::1:99:ff")).toEqual({ host: "fe80::1", pid: "99" });
  });

  test("tolerates identities without a pid", () => {
    expect(F.m.splitIdentity("lonely")).toEqual({ host: "lonely", pid: "" });
  });
});

describe("niceTicks", () => {
  test("picks round steps", () => {
    expect(F.m.niceTicks(87)).toEqual([0, 25, 50, 75, 100]);
    expect(F.m.niceTicks(100)).toEqual([0, 25, 50, 75, 100]);
    expect(F.m.niceTicks(8)).toEqual([0, 2, 4, 6, 8]);
    expect(F.m.niceTicks(4)).toEqual([0, 1, 2, 3, 4]);
    expect(F.m.niceTicks(15)).toEqual([0, 5, 10, 15]);
    expect(F.m.niceTicks(35)).toEqual([0, 10, 20, 30, 40]);
    expect(F.m.niceTicks(0.3)).toEqual([0, 0.1, 0.2, 0.3]);
    expect(F.m.niceTicks(1000, 2)).toEqual([0, 500, 1000]);
  });

  test("has a single tick for an empty range", () => {
    expect(F.m.niceTicks(0)).toEqual([0]);
    expect(F.m.niceTicks(-3)).toEqual([0]);
  });
});
