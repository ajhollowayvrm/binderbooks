/* The money formulas, and the migration that rewrites the whole ledger on every
   load. These decide every number the app shows, and until now nothing checked
   them. Each test names the wrong number it would catch. */
import { describe, it, expect } from "vitest";
import {
  ripValue, ripCostOf, ripPL, ripHitShares,
  saleNet, saleBasis, invBasis, gradeRange, fmtRange, fmt,
  splitEvenly, migrate, seed,
} from "./App.jsx";

const hit = (id, value) => ({ id, name: `card-${id}`, value });
const rip = (over = {}) => ({ id: "r1", product: "ETB", cost: 0, hits: [], ...over });

describe("rip cost", () => {
  it("takes the linked buy's cost, not the rip's own", () => {
    const buys = [{ id: "b1", cost: 300 }];
    expect(ripCostOf(rip({ buyId: "b1", cost: 999 }), buys)).toBe(300);
  });

  it("falls back to the rip's own cost when no buy is linked", () => {
    expect(ripCostOf(rip({ cost: 120 }), [])).toBe(120);
  });

  it("reads a linked buy that no longer exists as zero, not NaN", () => {
    // a deleted buy must not turn the whole scoreboard into "$NaN"
    expect(ripCostOf(rip({ buyId: "gone" }), [])).toBe(0);
    expect(ripPL(rip({ buyId: "gone", hits: [hit("h1", 10)] }), [])).toBe(10);
  });
});

describe("ripHitShares", () => {
  it("splits the cost in proportion to pull value", () => {
    const r = rip({ cost: 300, hits: [hit("a", 500), hit("b", 500)] });
    expect(ripHitShares(r, [])).toEqual({ a: 150, b: 150 });
  });

  it("gives the chase most of the box", () => {
    const r = rip({ cost: 300, hits: [hit("chase", 500), hit("filler", 2)] });
    const s = ripHitShares(r, []);
    expect(s.chase).toBeGreaterThan(s.filler * 100);
  });

  it("always sums back to the rip cost, rounding cents included", () => {
    // three-way splits do not divide evenly. If the drift correction breaks,
    // the binder's cost basis stops matching the cash that went out.
    const r = rip({ cost: 100, hits: [hit("a", 1), hit("b", 1), hit("c", 1)] });
    const s = ripHitShares(r, []);
    const sum = Object.values(s).reduce((a, b) => a + b, 0);
    expect(Math.round(sum * 100) / 100).toBe(100);
  });

  it("sums back to the cost across many awkward splits", () => {
    for (const cost of [0.01, 9.99, 100, 322.35, 1000.03]) {
      for (const n of [1, 2, 3, 7, 11]) {
        const hits = Array.from({ length: n }, (_, i) => hit(`h${i}`, i + 1));
        const sum = Object.values(ripHitShares(rip({ cost, hits }), []))
          .reduce((a, b) => a + b, 0);
        expect(Math.round(sum * 100) / 100).toBe(cost);
      }
    }
  });

  it("splits evenly when no hit has a value", () => {
    const r = rip({ cost: 90, hits: [hit("a", 0), hit("b", 0), hit("c", 0)] });
    expect(ripHitShares(r, [])).toEqual({ a: 30, b: 30, c: 30 });
  });

  it("gives every hit zero when the rip cost nothing", () => {
    const r = rip({ cost: 0, hits: [hit("a", 50)] });
    expect(ripHitShares(r, [])).toEqual({ a: 0 });
  });
});

describe("saleNet", () => {
  it("subtracts fees, shipping, sales tax and the consignment cut", () => {
    expect(saleNet({ price: 100, fees: 13, shipping: 5, tax: 8, consign: 2 })).toBe(72);
  });

  it("subtracts sales tax on its own", () => {
    expect(saleNet({ price: 100, tax: 8.25 })).toBe(91.75);
  });

  it("treats missing deductions as zero, never NaN", () => {
    expect(saleNet({ price: 100 })).toBe(100);
    expect(saleNet({})).toBe(0);
  });

  it("reads a number typed as a string", () => {
    // every money input in the app stores a string
    expect(saleNet({ price: "100", fees: "13.50" })).toBe(86.5);
  });
});

describe("saleBasis", () => {
  it("adds up the card lines", () => {
    expect(saleBasis({ cards: [{ basis: 10 }, { basis: 5.5 }] })).toBe(15.5);
  });

  it("is zero for a sale with no card lines", () => {
    expect(saleBasis({})).toBe(0);
  });
});

describe("invBasis", () => {
  it("counts the card, the grading fee and the card's share of postage", () => {
    // all three, or a graded card's ROI reads too high
    expect(invBasis({ cost: 100, gradingCost: 25, gradingShip: 3.5 })).toBe(128.5);
  });

  it("is just the cost for a raw card", () => {
    expect(invBasis({ cost: 40 })).toBe(40);
  });
});

describe("gradeRange", () => {
  // gradeEst is keyed by the bare grade off that company's ladder ("10", "9.5")
  const atGrading = (gradeEst, grader = "PSA") => ({ status: "At grading", grader, gradeEst });

  it("spans the lowest and highest estimate that was filled in", () => {
    expect(gradeRange(atGrading({ "10": 500, "9": 120, "8": 60 })))
      .toEqual({ lo: 60, hi: 500 });
  });

  it("ignores blank and zero estimates", () => {
    expect(gradeRange(atGrading({ "10": 500, "9": 0 })))
      .toEqual({ lo: 500, hi: 500 });
  });

  it("reads each company's own ladder", () => {
    // "9.5" is a CGC grade and not a PSA one. A CGC card valued off the PSA
    // ladder drops its 9.5 estimate; a PSA card must not pick one up.
    expect(gradeRange(atGrading({ "10": 400, "9.5": 250 }, "CGC")))
      .toEqual({ lo: 250, hi: 400 });
    expect(gradeRange(atGrading({ "10": 400, "9.5": 250 }, "PSA")))
      .toEqual({ lo: 400, hi: 400 });
  });

  it("is null for a card that is not at the graders", () => {
    expect(gradeRange({ status: "Kept", gradeEst: { "10": 500 } })).toBeNull();
  });

  it("is null when no estimate was entered", () => {
    expect(gradeRange(atGrading({}))).toBeNull();
  });
});

describe("splitEvenly", () => {
  it("splits in cents so the shares add back exactly", () => {
    // this is the grading postage split; a lost cent moves a card's basis
    for (const [total, n] of [[10, 3], [0.05, 3], [99.99, 7], [25, 4]]) {
      const parts = splitEvenly(total, n);
      expect(parts).toHaveLength(n);
      expect(Math.round(parts.reduce((a, b) => a + b, 0) * 100) / 100).toBe(total);
    }
  });
});

describe("formatting", () => {
  it("puts the minus sign before the dollar sign", () => {
    expect(fmt(-12.5)).toBe("-$12.50");
    expect(fmt(1234.5)).toBe("$1,234.50");
  });

  it("collapses a range with one value to a single figure", () => {
    expect(fmtRange({ lo: 50, hi: 50 })).toBe("$50.00");
    expect(fmtRange({ lo: 50, hi: 90 })).toBe("$50.00 – $90.00");
  });
});

describe("migrate", () => {
  it("does not throw on an empty object", () => {
    expect(() => migrate({})).not.toThrow();
  });

  it("gives every inventory card the fields the app reads", () => {
    const out = migrate({ inventory: [{ id: "c1", name: "Pikachu" }], buys: [], sales: [], rips: [] });
    const c = out.inventory[0];
    for (const k of ["status", "gradingCost", "gradingShip", "variant", "grader", "lang", "tcgplayerId", "productId"])
      expect(c).toHaveProperty(k);
    expect(c.status).toBe("Kept");
    expect(c.lang).toBe("en");
  });

  it("keeps a value the card already has", () => {
    const out = migrate({ inventory: [{ id: "c1", name: "x", status: "Sold", lang: "jp" }], buys: [], sales: [], rips: [] });
    expect(out.inventory[0].status).toBe("Sold");
    expect(out.inventory[0].lang).toBe("jp");
  });

  it("gives a card already at the graders a grader to be valued against", () => {
    const out = migrate({ inventory: [{ id: "c1", name: "x", status: "At grading" }], buys: [], sales: [], rips: [] });
    expect(out.inventory[0].grader).toBeTruthy();
  });

  it("converts a legacy single-card sale to the cards array", () => {
    const out = migrate({
      version: 1, buys: [], rips: [], inventory: [],
      sales: [{ id: "s1", cardName: "Umbreon ex", cardSet: "Prismatic", cardNumber: "161", costBasis: 40, price: 100 }],
    });
    const line = out.sales.find((s) => s.id === "s1").cards[0];
    expect(line.name).toBe("Umbreon ex");
    expect(line.basis).toBe(40);
  });

  it("is idempotent — running it twice changes nothing", () => {
    // migrate runs on every local AND remote load, so a second pass must be a
    // no-op. A pass that re-seeds or re-splits would drift the ledger on sync.
    const once = migrate(seed());
    const twice = migrate(JSON.parse(JSON.stringify(once)));
    expect(twice).toEqual(once);
  });

  it("leaves the seed ledger's own numbers readable", () => {
    const s = migrate(seed());
    expect(Array.isArray(s.buys)).toBe(true);
    expect(Array.isArray(s.sales)).toBe(true);
    for (const b of s.buys) expect(Number.isFinite(Number(b.cost))).toBe(true);
    for (const x of s.sales) expect(Number.isFinite(saleNet(x))).toBe(true);
  });

  it("ships no buyer names in the starter data", () => {
    // the starter ledger goes into a PUBLIC bundle; these were real customers
    const refs = migrate(seed()).sales.map((s) => s.item || "").join(" ");
    expect(refs).not.toMatch(/[A-Z][a-z]+\s+[A-Z][a-z]+/);
  });
});
