-- =====================================================================
-- ЭКСПЕРИМЕНТ: допуск опоздания +1 календарный день по МСК.
-- Основное решение (допуск 0, витрина dm.mart_otif_line, q1_otif.sql) НЕ меняется.
-- Тот же знаменатель: активные строки с плановой датой 2026-02-01…2026-07-31, приёмки до 2026-08-12.
-- Дата приёмки сравнивается как ДАТА по МСК: 23:59:59 МСК дня D+1 → в допуске, 00:00:00 МСК дня D+2 → нет.
-- =====================================================================
with params as (select 1 as tol_days, date '2026-08-12' as as_of),
base as (
    select l.order_id, l.line_no, l.master_supplier_id, l.qty, l.planned_delivery_date as pdd,
           -- строгая оценка: только accepted
           coalesce(sum(r.qty_received) filter (where r.quality_status = 'accepted'
                      and r.received_date_msk <= l.planned_delivery_date), 0)                as acc_0,
           coalesce(sum(r.qty_received) filter (where r.quality_status = 'accepted'
                      and r.received_date_msk <= l.planned_delivery_date + p.tol_days), 0)   as acc_1,
           -- мягкая оценка: partially_rejected засчитан целиком
           coalesce(sum(r.qty_received) filter (where r.quality_status <> 'rejected'
                      and r.received_date_msk <= l.planned_delivery_date), 0)                as nr_0,
           coalesce(sum(r.qty_received) filter (where r.quality_status <> 'rejected'
                      and r.received_date_msk <= l.planned_delivery_date + p.tol_days), 0)   as nr_1
    from dm.fct_po_line l
    cross join params p
    left join dm.fct_receipt r on r.order_id = l.order_id and r.line_no = l.line_no
                              and r.received_date_msk <= p.as_of
    where l.status = 'active' and l.planned_delivery_date between '2026-02-01' and '2026-07-31'
    group by l.order_id, l.line_no, l.master_supplier_id, l.qty, l.planned_delivery_date
)
select count(*)                                                   as lines_denominator,
       round(100 * avg((acc_0 >= qty)::int), 1)                   as strict_tol0,
       round(100 * avg((acc_1 >= qty)::int), 1)                   as strict_tol1,
       round(100 * avg((nr_0  >= qty)::int), 1)                   as lenient_tol0,
       round(100 * avg((nr_1  >= qty)::int), 1)                   as lenient_tol1,
       count(*) filter (where acc_0 < qty and acc_1 >= qty)       as lines_became_otif_strict,
       count(*) filter (where acc_0 >= qty and acc_1 < qty)       as lines_lost_otif_strict
from base;
