import React from "react";
import { fmt, fmtRange, FadeImg, gradeRange, invBasis, isJP, slabOf, statusLabel, VARIANT_SHORT } from "../App.jsx";

/* The tile's price-direction strip: a dozen market points as a hairline,
   colored by where the month ended up. Text stays in ink tokens — the line
   alone carries the direction, the percent names it. */
function TrendLine({ trend }) {
  if (!trend || trend.pts.length < 2) return null;
  const W = 56, H = 14, PAD = 1.5;
  const lo = Math.min(...trend.pts), hi = Math.max(...trend.pts);
  const span = hi - lo || 1;
  const x = (i) => PAD + (i / (trend.pts.length - 1)) * (W - PAD * 2);
  const y = (v) => H - PAD - ((v - lo) / span) * (H - PAD * 2);
  const d = trend.pts.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("");
  const up = trend.delta >= 0;
  return (
    <span className="cl-binder-trend">
      <svg viewBox={`0 0 ${W} ${H}`} className="cl-binder-trend-svg" aria-hidden="true">
        <path d={d} fill="none" stroke={up ? "var(--pos)" : "var(--neg)"} strokeWidth="1.5" strokeLinejoin="round" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
      </svg>
      <span className={"cl-binder-delta " + (up ? "pos" : "neg")}>{up ? "+" : ""}{trend.delta}%</span>
    </span>
  );
}

/* A graded card is drawn in its slab: a plastic frame and the grader's label
   strip above the art, in that company's colors. The art is the same raw scan
   every tile uses, because no grader publishes slab photos. The frame alone
   marks the card as graded. */
const SLAB_LABELS = { PSA: "psa", CGC: "cgc", BGS: "bgs" };
// "10 Pristine" has no word here — the grade itself already says it, so a
// word beside it would just repeat "Pristine ... Pristine".
const GRADE_WORDS = { "10": "GEM MINT", "9.5": "MINT+", "9": "MINT", "8.5": "NM-MT+", "8": "NM-MT", "7.5": "NM+", "7": "NM", "6.5": "EX-MT+", "6": "EX-MT" };
function SlabLabel({ slab }) {
  return (
    <span className={"cl-slab-label " + (SLAB_LABELS[slab.grader] || "other")}>
      <span className="cl-slab-co">{slab.grader}</span>
      <span className="cl-slab-word">{GRADE_WORDS[slab.grade] || ""}</span>
      <span className="cl-slab-grade">{slab.grade}</span>
    </span>
  );
}

// A card's picture, as resolved by useCardImages. undefined = still
// looking, null = no match found (JP, a stamped print, a SKU the database
// hasn't indexed) — only that last state gets the name tile, so a slow
// connection reads as "loading", not "no image".
//
// Memoized so a card whose image just resolved only re-renders itself, not
// the whole grid. `onOpen` must be a stable reference (the parent's
// `setViewId`) — this component calls it with its own `card.id`.
function BinderCard({ card, img, rarity, trend, onOpen }) {
  const slab = slabOf(card.grade);
  const range = gradeRange(card);
  const basis = invBasis(card);
  const held = card.date ? Math.max(0, Math.round((Date.now() - new Date(card.date + "T12:00:00").getTime()) / 864e5)) : null;
  const line2 = [card.set, rarity, card.number].filter(Boolean).join(" • ");
  const art = img
    ? <FadeImg className="cl-binder-img" src={img} alt={card.name} loading="lazy" />
    : <span className={"cl-binder-ph" + (img === null ? " named" : " cl-shimmer")}>
        {img === null ? (card.name || "Unnamed card") : <span className="holo-dot" />}
      </span>;
  return (
    <button className={"cl-binder-card cl-row-enter" + (card.status === "Sold" ? " sold" : "")} onClick={() => onOpen(card.id)} title={card.name || "Unnamed card"}>
      <span className="cl-binder-artwrap">
        {slab
          ? <span className="cl-slab"><SlabLabel slab={slab} /><span className="cl-binder-imgwrap in-slab">{art}</span></span>
          : <span className="cl-binder-imgwrap">{art}</span>}
        {card.status === "Sold" && <span className="cl-binder-badge">Sold</span>}
        {card.status === "At grading" && <span className="cl-binder-badge grading">{statusLabel(card)}</span>}
        {card.status === "Listed" && <span className="cl-binder-badge listed">Listed</span>}
      </span>
      <span className="cl-binder-cap">
        <span className="cl-binder-name">{card.name || "Unnamed card"}{isJP(card) ? " (JP)" : ""}</span>
        {line2 && <span className="cl-binder-line">{line2}</span>}
        <span className="cl-binder-line chips">
          <span className={"cl-binder-cond" + (slab ? " " + (SLAB_LABELS[slab.grader] || "other") : "")}>{slab ? `${slab.grader} ${slab.grade}${GRADE_WORDS[slab.grade] ? ` (${GRADE_WORDS[slab.grade].charAt(0) + GRADE_WORDS[slab.grade].slice(1).toLowerCase()})` : ""}` : card.grade === "Raw" ? "Raw" : card.grade}</span>
          {card.variant && <> • {VARIANT_SHORT[card.variant] || card.variant}</>}
          {card.source && <> • {card.source}</>}
        </span>
        <span className="cl-binder-worth">
          <TrendLine trend={trend} />
          <span className="cl-binder-money">{range ? fmtRange(range) : fmt(Number(card.value) || 0)}</span>
        </span>
        <span className="cl-binder-line meta">
          <span>{basis > 0 ? `basis ${fmt(basis)}` : ""}</span>
          {held != null && <span>{held} day{held === 1 ? "" : "s"}</span>}
        </span>
      </span>
    </button>
  );
}

export default React.memo(BinderCard);
