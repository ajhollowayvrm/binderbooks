import React from "react";
import { Pencil, Trash2 } from "lucide-react";
import { fmt, saleNet, saleBasis, SaleForm } from "../App.jsx";

/* One sale, memoized so editing/deleting one row doesn't re-render every
   other row. `inventory` is only needed by `SaleForm` while editing, and
   inventory changes on nearly every sale — so a plain shallow memo would
   invalidate every row whenever any card sells. The custom comparator below
   ignores `inventory` unless this particular row is the one being edited. */
function SaleRow({ sale: x, inventory, isEditing, onEdit, onDelete, onSave, onCancelEdit }) {
  if (isEditing) return <SaleForm initial={x} inventory={inventory} onSave={onSave} onCancel={onCancelEdit} />;
  const net = saleNet(x);
  const ded = (Number(x.fees) || 0) + (Number(x.shipping) || 0) + (Number(x.tax) || 0) + (Number(x.consign) || 0);
  const cards = x.cards || [];
  const title = cards.length ? cards[0].name + (cards.length > 1 ? ` +${cards.length - 1}` : "") : (x.item || "Sale");
  const basis = saleBasis(x);
  const ref = cards.length && x.item ? ` · ${x.item}` : "";
  return (
    <div className="cl-row cl-row-enter">
      <div className="cl-row-main"><div className="cl-row-title">{title}</div><div className="cl-row-meta"><span className="cl-chip">{x.channel}</span> {x.date}{ref}{ded > 0 && ` · −${ded.toFixed(2)} fees`}</div></div>
      <div className="cl-card-num"><div className="cl-money in">{fmt(net)}</div>{basis > 0 ? <div className="cl-row-meta">profit {fmt(net - basis)}</div> : null}</div>
      <button className="cl-x" onClick={() => onEdit(x.id)}><Pencil size={13} /></button>
      <button className="cl-x" onClick={() => onDelete(x.id)}><Trash2 size={13} /></button>
    </div>
  );
}

const areEqual = (prev, next) =>
  prev.sale === next.sale &&
  prev.isEditing === next.isEditing &&
  (!next.isEditing || prev.inventory === next.inventory) &&
  prev.onEdit === next.onEdit &&
  prev.onDelete === next.onDelete &&
  prev.onSave === next.onSave &&
  prev.onCancelEdit === next.onCancelEdit;

export default React.memo(SaleRow, areEqual);
