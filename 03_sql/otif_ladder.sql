-- =====================================================================
-- otif_ladder.sql — «лестница определений»: как одна и та же выгрузка даёт и ~94%, и ~71%, и ~46%.
-- Период как в Q1: строки с плановой датой 2026-02-01 … 2026-07-31.
-- =====================================================================
with base as (
    select l.order_id, l.line_no, l.qty, l.planned_delivery_date as pdd,
           count(r.receipt_id)                                                            as n_rcpt,
           min(r.received_date_msk)                                                       as first_d,
           max(r.received_date_msk)                                                       as last_d,
           max((r.received_at_utc at time zone 'UTC')::date)                              as last_d_utc,
           coalesce(sum(r.qty_received), 0)                                               as q_all,
           coalesce(sum(r.qty_received) filter (where r.quality_status = 'accepted'), 0)  as q_acc,
           coalesce(sum(r.qty_received) filter (where r.quality_status = 'accepted'
                                                  and r.received_date_msk <= l.planned_delivery_date), 0) as q_acc_ot,
           coalesce(sum(r.qty_received) filter (where r.quality_status <> 'rejected'
                                                  and r.received_date_msk <= l.planned_delivery_date), 0) as q_nonrej_ot,
           coalesce(sum(r.qty_received) filter (where r.quality_status = 'accepted'
                                                  and (r.received_at_utc at time zone 'UTC')::date <= l.planned_delivery_date), 0) as q_acc_ot_utc
    from dm.fct_po_line l
    left join dm.fct_receipt r on r.order_id = l.order_id and r.line_no = l.line_no
                              and r.received_date_msk <= date '2026-08-12'   -- как в витрине: без приёмок после даты расчёта
    where l.status = 'active'
      and l.planned_delivery_date between '2026-02-01' and '2026-07-31'
    group by l.order_id, l.line_no, l.qty, l.planned_delivery_date
),
events as (
    select avg((r.quality_status = 'accepted')::int) as ev_accepted
    from dm.fct_receipt r join dm.fct_po_line l using (order_id, line_no)
    where l.status = 'active' and l.planned_delivery_date between '2026-02-01' and '2026-07-31'
)
select ord, definition, round(100 * value, 1) as pct
from (
    select 1 as ord, 'Строка хоть как-то поставлена (есть приёмка)'                       as definition, avg((n_rcpt > 0)::int)::numeric as value from base
    union all select 2, 'Доля событий приёмки без брака (accepted)',                      (select ev_accepted from events)
    union all select 3, 'In-Full: принято (accepted) >= заказано, в любой срок',            avg((q_acc >= qty)::int) from base
    union all select 4, 'On-Time по первой приёмке (пришла первая партия)',                avg(coalesce(first_d <= pdd, false)::int) from base
    union all select 5, 'On-Time по последней приёмке, допуск +7 дней',                    avg(coalesce(last_d <= pdd + 7, false)::int) from base
    union all select 6, 'On-Time по последней приёмке, допуск +3 дня',                     avg(coalesce(last_d <= pdd + 3, false)::int) from base
    union all select 7, 'On-Time по последней приёмке, без допуска',                       avg(coalesce(last_d <= pdd, false)::int) from base
    union all select 8, 'OTIF, partially_rejected засчитан целиком',                       avg((q_nonrej_ot >= qty)::int) from base
    union all select 9, 'OTIF с датой приёмки по UTC (ошибка часового пояса)',             avg((q_acc_ot_utc >= qty)::int) from base
    union all select 10, 'OTIF (наше определение): accepted, к плановой дате МСК, в полном объёме', avg((q_acc_ot >= qty)::int) from base
) x
order by ord;
