import React from "react";
import { fmt, FadeImg } from "../App.jsx";

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

// A card's picture, as resolved by useCardImages. undefined = still
// looking, null = no match found (JP, a stamped print, a SKU the database
// hasn't indexed) — only that last state gets the name tile, so a slow
// connection reads as "loading", not "no image".
//
// Memoized so a card whose image just resolved only re-renders itself, not
// the whole grid. `onOpen` must be a stable reference (the parent's
// `setViewId`) — this component calls it with its own `card.id`.
function BinderCard({ card, img, trend, onOpen }) {
  return (
    <button className="cl-binder-card cl-row-enter" onClick={() => onOpen(card.id)} title={card.name}>
      <span className="cl-binder-imgwrap">
        {img
          ? <FadeImg className="cl-binder-img" src={img} alt={card.name} loading="lazy" />
          : <span className={"cl-binder-ph" + (img === null ? " named" : " cl-shimmer")}>
              {img === null ? card.name : <span className="holo-dot" />}
            </span>}
        {card.status === "Sold" && <span className="cl-binder-sold">Sold</span>}
      </span>
      <span className="cl-binder-cap">
        <span className="cl-binder-name">{card.name}</span>
        <span className="cl-binder-worth">
          <span className="cl-binder-money">{fmt(Number(card.value) || 0)}</span>
          <TrendLine trend={trend} />
        </span>
      </span>
    </button>
  );
}

export default React.memo(BinderCard);
