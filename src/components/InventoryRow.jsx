import React from "react";
import { Pencil, Trash2 } from "lucide-react";
import { fmt, fmtRange, stCls, statusLabel, isJP, invBasis, gradeRange, VARIANT_SHORT, InvForm } from "../App.jsx";

/* One inventory card, memoized so opening the modal, editing, or deleting one
   card doesn't re-render every other row. `onEdit`/`onDelete`/`onOpen` must be
   stable — this component calls them with its own `card.id`. */
function InventoryRow({ card: c, isEditing, onEdit, onDelete, onOpen, onSave, onCancelEdit }) {
  if (isEditing) return <InvForm initial={c} onSave={onSave} onCancel={onCancelEdit} />;
  return (
    <div className={"cl-row click" + (c.status === "Sold" ? " sold" : "")} onClick={() => onOpen(c.id)}>
      <span className="holo-dot" />
      <div className="cl-row-main">
        <div className="cl-row-title">{c.name}</div>
        <div className="cl-row-meta"><span className={"cl-st " + stCls(c.status)}>{statusLabel(c)}</span><span className="cl-chip">{c.grade}</span>{isJP(c) && <span className="cl-chip">JP</span>}{c.variant && <span className="cl-chip">{VARIANT_SHORT[c.variant] || c.variant}</span>}{c.set ? `${c.set}${c.number ? " · " + c.number : ""} · ` : ""}{c.source}</div>
      </div>
      <div className="cl-card-num"><div className="cl-money" style={{ color: "var(--holo2)" }}>{gradeRange(c) ? fmtRange(gradeRange(c)) : fmt(Number(c.value) || 0)}</div>{invBasis(c) ? <div className="cl-row-meta">basis {fmt(invBasis(c))}</div> : null}</div>
      <button className="cl-x" onClick={(e) => { e.stopPropagation(); onEdit(c.id); }}><Pencil size={13} /></button>
      <button className="cl-x" onClick={(e) => { e.stopPropagation(); onDelete(c.id); }}><Trash2 size={13} /></button>
    </div>
  );
}

export default React.memo(InventoryRow);
