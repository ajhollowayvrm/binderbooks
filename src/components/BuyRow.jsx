import React from "react";
import { PackageOpen, Pencil, Trash2 } from "lucide-react";
import { fmt, BuyForm } from "../App.jsx";

/* One buy, memoized so editing/deleting/toggling one row doesn't re-render
   every other row in the list. `onEdit`/`onDelete`/`onToggleRipped` must be
   stable (useCallback in the parent) — this component calls them with its
   own `buy.id`, so the closure recreated on every render lives inside the
   memo boundary, not as a changing prop. */
function BuyRow({ buy: b, isEditing, onEdit, onDelete, onToggleRipped, onSave, onCancelEdit }) {
  if (isEditing) return <BuyForm initial={b} onSave={onSave} onCancel={onCancelEdit} />;
  return (
    <div className="cl-row">
      <div className="cl-row-main">
        <div className="cl-row-title">{b.name || b.item}{b.seed && <span className="cl-seed">starter</span>}</div>
        <div className="cl-row-meta"><span className="cl-chip">{b.category}</span>{b.ripped && <span className="cl-st grading">ripped</span>} {b.source} · {b.date}{b.name && b.item && b.name !== b.item ? ` · ${b.item}` : ""}</div>
      </div>
      <div className="cl-money out">{fmt(Number(b.cost) || 0)}</div>
      <button className={"cl-x" + (b.ripped ? " on" : "")} title={b.ripped ? "Marked ripped — click to unmark" : "Mark as ripped"} onClick={() => onToggleRipped(b.id)}><PackageOpen size={13} /></button>
      <button className="cl-x" onClick={() => onEdit(b.id)}><Pencil size={13} /></button>
      <button className="cl-x" onClick={() => onDelete(b.id)}><Trash2 size={13} /></button>
    </div>
  );
}

export default React.memo(BuyRow);
