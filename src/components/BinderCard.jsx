import React from "react";
import { fmt, FadeImg } from "../App.jsx";

// A card's picture, as resolved by useCardImages. undefined = still
// looking, null = no match found (JP, a stamped print, a SKU the database
// hasn't indexed) — only that last state gets the name tile, so a slow
// connection reads as "loading", not "no image".
//
// Memoized so a card whose image just resolved only re-renders itself, not
// the whole grid. `onOpen` must be a stable reference (the parent's
// `setViewId`) — this component calls it with its own `card.id`.
function BinderCard({ card, img, onOpen }) {
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
        <span className="cl-binder-money">{fmt(Number(card.value) || 0)}</span>
      </span>
    </button>
  );
}

export default React.memo(BinderCard);
