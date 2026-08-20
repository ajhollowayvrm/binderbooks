import React, { useState } from "react";
import { ChevronDown, ChevronRight, Trash2, X } from "lucide-react";
import { useAutoAnimate } from "@formkit/auto-animate/react";
import { fmt, isJP, ripValue, HitForm, FadeImg } from "../App.jsx";

/* One rip, memoized so expanding/collapsing or adding a hit to one rip
   doesn't re-render every other rip card. `pl`/`cost` are precomputed by the
   parent as numbers (cheaper prop comparison than passing the whole `buys`
   array) — P&L genuinely depends on buys, so this is an inherent coupling,
   not a memoization bug. `onToggle`/`onDelete`/`onAddHit`/`onEditHit`/
   `onDeleteHit` must be stable — this component calls them with its own
   `rip.id`. `images` is an `{id: url|null|undefined}` map for this rip's
   hits — the caller must pass the same stable empty-object reference for
   every rip that isn't open, or this memoization is defeated for every
   collapsed card. Which hit is being edited stays local: a collapsed rip
   renders no hits, so lifting it would only add a prop to keep stable. */
function RipCard({ rip: r, pl, cost, isOpen, images, onToggle, onDelete, onAddHit, onEditHit, onDeleteHit }) {
  const [editHitId, setEditHitId] = useState(null);
  const [hitsRef] = useAutoAnimate(); // adds/deletes/edit-swaps in the hit list slide instead of snapping
  const packLabel = r.setPacks && r.setPacks.length
    ? r.setPacks.map((p) => `${p.packs || "?"} ${p.set || "?"}`).join(" + ")
    : (r.packs ? `${r.packs} packs` : "");
  return (
    <div className="cl-card cl-row-enter">
      <button className="cl-card-head" onClick={() => onToggle(r.id)}>
        <div className="cl-row-main"><div className="cl-row-title">{isOpen ? <ChevronDown size={15} /> : <ChevronRight size={15} />} {r.product || "Rip"}</div><div className="cl-row-meta">{packLabel ? `${packLabel} · ` : ""}{r.source || "—"} · {(r.hits || []).length} hits · {r.date}</div></div>
        <div className="cl-card-num"><div className={"cl-money " + (pl >= 0 ? "pos" : "neg")}>{fmt(pl)}</div><div className="cl-row-meta">{r.buyId ? "from buy" : "cost"} {fmt(cost)}</div></div>
      </button>
      {isOpen && <div className="cl-card-body cl-tabpane">
        <div className="cl-hits" ref={hitsRef}>
          {(r.hits || []).length === 0 && <div className="cl-empty">No hits added.</div>}
          {(r.hits || []).map((h) => (editHitId === h.id
            ? <HitForm key={h.id} initial={h} onSave={(u) => { onEditHit(r.id, u); setEditHitId(null); }} onCancel={() => setEditHitId(null)} />
            : (() => { const img = images[h.id]; return (<div key={h.id} className="cl-hit click cl-row-enter" onClick={() => setEditHitId(h.id)}><span className="cl-hit-imgwrap">{img ? <FadeImg className="cl-hit-img" src={img} alt={h.name} loading="lazy" /> : <span className={"cl-hit-ph" + (img === null ? " named" : " cl-shimmer")}>{img === null ? h.name : <span className="holo-dot" />}</span>}</span><div className="cl-hit-main"><div className="cl-hit-name">{h.name}</div><div className="cl-row-meta">{h.grade && h.grade !== "Raw" && <span className="cl-chip">{h.grade}</span>}{isJP(h) && <span className="cl-chip">JP</span>}{h.set ? `${h.set}${h.number ? ` · ${h.number}` : ""}` : ""}</div></div><div className="cl-money">{fmt(Number(h.value) || 0)}</div><button className="cl-x" onClick={(e) => { e.stopPropagation(); onDeleteHit(r.id, h.id); }}><X size={13} /></button></div>); })()))}
        </div>
        <HitForm onAdd={(h) => onAddHit(r.id, h)} />
        <div className="cl-card-foot"><span>Pulled value {fmt(ripValue(r))}</span><button className="cl-del" onClick={() => onDelete(r.id)}><Trash2 size={13} /> Delete rip</button></div>
      </div>}
    </div>
  );
}

export default React.memo(RipCard);
