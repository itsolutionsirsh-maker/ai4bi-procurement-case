"""
Независимая сверка Q1–Q3: та же логика, но на pandas и прямо по сырым CSV, без SQL-модели.
Если цифры совпадают с results/*.csv — в SQL нет ошибок джойнов, дублей и фильтров.
Запуск: python3 verify_pandas.py  (CSV лежат в ../data/)
"""
import pandas as pd
import numpy as np

D = "../data/"
rd = lambda f: pd.read_csv(D + f, sep=";", dtype=str)
h, l, r, s, it, u, fx = (rd(f) for f in ["po_headers.csv", "po_lines.csv", "receipts.csv",
                                          "suppliers.csv", "items.csv", "uom.csv", "fx_rates.csv"])
for c in ["qty", "price", "plan_price"]:
    l[c] = l[c].astype(float)
r["qty_received"] = r["qty_received"].astype(float)

# --- строки: убрать полные дубли, взять последнюю версию
l = l.drop_duplicates()
l["updated_at"] = pd.to_datetime(l["updated_at"])
l = l.sort_values("updated_at").groupby(["order_id", "line_no"], as_index=False).last()
l = l.merge(h, on="order_id")
l["order_date"] = pd.to_datetime(l["order_dttm_msk"]).dt.normalize()

# --- мастер-поставщик по ИНН: код с самой ранней valid_from
s["valid_from"] = pd.to_datetime(s["valid_from"])
first = s.groupby(["supplier_id", "inn"], as_index=False)["valid_from"].min().sort_values(["valid_from", "supplier_id"])
master = first.groupby("inn")["supplier_id"].first().rename("master").reset_index()
smap = first.merge(master, on="inn")[["supplier_id", "master"]]
l = l.merge(smap, on="supplier_id")

# --- курсы с протяжкой на выходные
fx["rate_date"] = pd.to_datetime(fx["rate_date"]); fx["rate_to_rub"] = fx["rate_to_rub"].astype(float)
days = pd.date_range("2024-01-01", "2026-08-12")
fxd = pd.concat([fx[fx.currency == c].set_index("rate_date")["rate_to_rub"].reindex(days).ffill()
                 .rename("rate").to_frame().assign(currency=c) for c in fx.currency.unique()])
fxd = fxd.reset_index().rename(columns={"index": "order_date"})
l = l.merge(fxd, on=["order_date", "currency"], how="left")
l.loc[l.currency == "RUB", "rate"] = 1.0
assert l["rate"].notna().all()
l["amount_rub"] = l.qty * l.price * l.rate

# ================= Q1: OTIF =================
r["d_msk"] = pd.to_datetime(r["received_at_utc"]).dt.tz_convert("Europe/Moscow").dt.tz_localize(None).dt.normalize()
a = l[(l.status == "active")].copy()
a["pdd"] = pd.to_datetime(a["planned_delivery_date"])
a = a[(a.pdd >= "2026-02-01") & (a.pdd < "2026-08-01")]
rr = r.merge(a[["order_id", "line_no", "pdd"]], on=["order_id", "line_no"])
ok = rr[(rr.quality_status == "accepted") & (rr.d_msk <= rr.pdd)].groupby(["order_id", "line_no"])["qty_received"].sum()
a = a.set_index(["order_id", "line_no"])
a["acc_ot"] = ok.reindex(a.index).fillna(0)
a["otif"] = a.acc_ot >= a.qty - 1e-9   # float: 53.7+97.82 = 151.51999… < 151.52 (PO500016/1), таких строк 1 096 (подсчёт — в конце файла)
q1p = a.groupby("master").agg(n=("otif", "size"), otif=("otif", "mean"))
q1p = q1p[q1p.n >= 20]
q1 = pd.read_csv("results/q1_otif.csv").drop_duplicates("master_supplier_id").set_index("master_supplier_id")
diff = (q1p.otif * 100 - q1.otif_period_pct).abs().max()
print(f"Q1: поставщиков pandas={len(q1p)} sql={len(q1)}, макс. расхождение OTIF={diff:.2f} п.п. "
      f"(округление до 0,1 даёт до 0,05)")
assert len(q1p) == len(q1) and diff <= 0.051

# ================= Q2: ценовые аномалии =================
u["factor_to_base"] = u["factor_to_base"].astype(float)
b = l[(l.status == "active") & (l.currency != "CNY") & (l.order_date >= "2026-04-01") & (l.order_date < "2026-07-01")]
b = b.merge(u[["uom_code", "factor_to_base"]], on="uom_code")
b["qty_base"] = b.qty * b.factor_to_base
sp = b.groupby(["item_id", "uom_code", "master"]).agg(amt=("amount_rub", "sum"), qb=("qty_base", "sum")).reset_index()
sp["p"] = sp.amt / sp.qb
rows = []
for (item, uom), g in sp.groupby(["item_id", "uom_code"]):
    for _, x in g.iterrows():
        others = g[g.master != x.master].p
        if len(others) >= 2:
            med = others.median()
            dev = x.p / med - 1
            if abs(dev) > 0.15:
                rows.append((item, x.master, dev * 100, (x.p - med) * x.qb))
q2p = pd.DataFrame(rows, columns=["item", "sup", "dev", "eff"])
q2p = q2p.reindex(q2p.eff.abs().sort_values(ascending=False).index).head(15).reset_index(drop=True)
q2 = pd.read_csv("results/q2_price_anomalies.csv")
same = (q2p.item.values == q2.item_id.values).all() and (q2p.sup.values == q2.supplier_id.values).all()
print(f"Q2: топ-15 совпадает по позициям и поставщикам: {same}; "
      f"макс. расхождение отклонения={np.abs(q2p.dev.values - q2.deviation_pct.values).max():.2f} п.п.")
assert same

# ================= Q3: концентрация =================
items = it.set_index("item_id")["category"]
c = l[(l.status == "active") & (l.order_date >= "2025-08-01") & (l.order_date < "2026-08-01")].copy()
c["category"] = c.item_id.map(items).fillna("(нет в справочнике)")
t = c.groupby(["category", "master"])["amount_rub"].sum().reset_index()
t = t.sort_values(["category", "amount_rub", "master"], ascending=[True, False, True])
t["share"] = t.amount_rub / t.groupby("category").amount_rub.transform("sum")
t["cum"] = t.groupby("category").share.cumsum()
t["core"] = (t.cum - t.share) < 0.8
q3p = t.groupby("category").core.sum()
q3 = pd.read_csv("results/q3_concentration.csv").drop_duplicates("category").set_index("category")["suppliers_for_80pct"]
print("Q3: число поставщиков для 80% совпадает по всем категориям:", (q3p.sort_index() == q3.sort_index()).all())
assert (q3p.sort_index() == q3.sort_index()).all()
print("Сверка пройдена.")

# ================= Справочно: сколько строк ломает float =================
# Метод: активные строки (последняя версия), все приёмки со статусом accepted, сумма в порядке времени приёмки.
# Считаем строки, где сумма в Decimal ровно равна заказу, а во float — меньше.
from decimal import Decimal
rr = r[r.quality_status == "accepted"].sort_values("received_at_utc")
acc = rr.groupby(["order_id", "line_no"])["qty_received"].apply(list)
act = l[l.status == "active"].set_index(["order_id", "line_no"])["qty"]
raw_qty = pd.read_csv(D + "po_lines.csv", sep=";", dtype=str).drop_duplicates()
raw_qty["updated_at"] = pd.to_datetime(raw_qty["updated_at"])
raw_qty = raw_qty.sort_values("updated_at").groupby(["order_id", "line_no"]).last()["qty"]
n_float = 0
for key, vals in acc.items():
    if key in act.index:
        q = raw_qty[key]
        if sum(Decimal(str(v)) for v in vals) == Decimal(q) and sum(vals) < float(q):
            n_float += 1
print(f"Справочно: строк, где float-сумма приёмок < заказа при точном равенстве в Decimal: {n_float}")
