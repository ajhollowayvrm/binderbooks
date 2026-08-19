import React from "react";
import { ChevronDown, ChevronRight, Trash2, X } from "lucide-react";
import { fmt, isJP, ripValue, HitForm } from "../App.jsx";

/* One rip, memoized so expanding/collapsing or adding a hit to one rip
   doesn't re-render every other rip card. `pl`/`cost` are precomputed by the
   parent as numbers (cheaper prop comparison than passing the whole `buys`
   array) — P&L genuinely depends on buys, so this is an inherent coupling,
   not a memoization bug. `onToggle`/`onDelete`/`onAddHit`/`onDeleteHit` must
   be stable — this component calls them with its own `rip.id`. */
function RipCard({ rip: r, pl, cost, isOpen, onToggle, onDelete, onAddHit, onDeleteHit }) {
  const packLabel = r.setPacks && r.setPacks.length
    ? r.setPacks.map((p) => `${p.packs || "?"} ${p.set || "?"}`).join(" + ")
    : (r.packs ? `${r.packs} packs` : "");
  return (
    <div className="cl-card cl-row-enter">
      <button className="cl-card-head" onClick={() => onToggle(r.id)}>
        <div className="cl-row-main"><div className="cl-row-title">{isOpen ? <ChevronDown size={15} /> : <ChevronRight size={15} />} {r.product || "Rip"}</div><div className="cl-row-meta">{packLabel ? `${packLabel} · ` : ""}{r.source || "—"} · {(r.hits || []).length} hits · {r.date}</div></div>
        <div className="cl-card-num"><div className={"cl-money " + (pl >= 0 ? "pos" : "neg")}>{fmt(pl)}</div><div className="cl-row-meta">{r.buyId ? "from buy" : "cost"} {fmt(cost)}</div></div>
      </button>
      {isOpen && <div className="cl-card-body">
        <div className="cl-hits">
          {(r.hits || []).length === 0 && <div className="cl-empty">No hits added.</div>}
          {(r.hits || []).map((h) => (<div key={h.id} className="cl-hit cl-row-enter"><span className="holo-dot" /><div className="cl-hit-main"><div className="cl-hit-name">{h.name}</div><div className="cl-row-meta">{h.grade && h.grade !== "Raw" && <span className="cl-chip">{h.grade}</span>}{isJP(h) && <span className="cl-chip">JP</span>}{h.set ? `${h.set}${h.number ? ` · ${h.number}` : ""}` : ""}</div></div><div className="cl-money">{fmt(Number(h.value) || 0)}</div><button className="cl-x" onClick={() => onDeleteHit(r.id, h.id)}><X size={13} /></button></div>))}
        </div>
        <HitForm onAdd={(h) => onAddHit(r.id, h)} />
        <div className="cl-card-foot"><span>Pulled value {fmt(ripValue(r))}</span><button className="cl-del" onClick={() => onDelete(r.id)}><Trash2 size={13} /> Delete rip</button></div>
      </div>}
    </div>
  );
}

export default React.memo(RipCard);
