-- =====================================================================
-- recon_turnover.sql — откуда может браться расхождение оборота «закупки vs финансы» на 8–10%.
-- Гипотеза для проверки с заказчиком, а не доказательство: формулы обоих отчётов мы пока не видели.
-- Период: 2025 календарный год. Оговорка: «заказано» — по дате заказа, «принято» — по дате приёмки,
-- поэтому часть разницы — переходящие заказы (заказаны в декабре 2024, приняты в 2025, и наоборот).
-- =====================================================================
with fx as (
    select rate_date, currency, rate_to_rub from dm.fx_rate_daily
),
raw_lines as (
    select l.*, h.order_dttm_msk::date as order_date, h.currency,
           row_number() over (partition by l.order_id, l.line_no, l.item_id, l.qty, l.price, l.plan_price,
                                           l.uom_code, l.planned_delivery_date, l.status, l.updated_at) as dup_rn
    from raw.po_lines l join raw.po_headers h using (order_id)
),
s as (
    select
      -- 1. Сырая выгрузка «как есть»: все строки, включая дубли, старые версии и отмены
      sum(r.qty::numeric * r.price::numeric * fx.rate_to_rub)                                         as s1_raw_all,
      -- 2. минус полные дубли
      sum(r.qty::numeric * r.price::numeric * fx.rate_to_rub) filter (where r.dup_rn = 1)             as s2_no_dups
    from raw_lines r
    join fx on fx.currency = r.currency and fx.rate_date = r.order_date
    where r.order_date between '2025-01-01' and '2025-12-31'
),
m as (
    select
      -- 3. последняя версия строки, все статусы
      sum(amount_rub)                                                              as s3_last_version,
      -- 4. минус отменённые = «заказано» (взгляд закупок)
      sum(amount_rub) filter (where status = 'active')                             as s4_ordered_active,
      -- 4a. то же, но с inner join на справочник номенклатуры (как делает типовой отчёт)
      sum(amount_rub) filter (where status = 'active' and not dq_item_unknown)     as s4a_ordered_known_items,
      -- 4b. то же, но с inner join на курсы без протяжки на выходные
      sum(amount_rub) filter (where status = 'active'
                              and (currency = 'RUB' or extract(isodow from order_date) < 6)) as s4b_ordered_no_weekend_fx,
      -- 4c. то же, если цены в заказах «CNY» на самом деле в долларах (дефект D7)
      sum(case when currency = 'CNY' then qty * price * (select rate_to_rub from dm.fx_rate_daily u
                                                         where u.currency = 'USD' and u.rate_date = order_date)
               else amount_rub end) filter (where status = 'active')               as s4c_ordered_cny_as_usd
    from dm.fct_po_line
    where order_date between '2025-01-01' and '2025-12-31'
),
f as (
    -- 5. «Принято» (вероятный взгляд финансов): принятое кол-во × цена, по дате приёмки МСК,
    --    включая приёмку по отменённым строкам. Как учитывать частичный брак (partially_rejected),
    --    неизвестно: в событии нет принятого количества (D14), поэтому даём оба крайних варианта.
    select sum(r.qty_received * l.price * l.fx_rate_to_rub)
             filter (where r.quality_status <> 'rejected')                                       as s5_received_not_rejected,
           sum(r.qty_received * l.price * l.fx_rate_to_rub)
             filter (where r.quality_status <> 'rejected' and l.status = 'active')               as s5a_received_active_only,
           sum(r.qty_received * l.price * l.fx_rate_to_rub)
             filter (where r.quality_status = 'accepted')                                        as s5b_received_accepted_only
    from dm.fct_receipt r
    join dm.fct_po_line l using (order_id, line_no)
    where r.received_date_msk between '2025-01-01' and '2025-12-31'
)
select step, round(value / 1e6, 1) as mln_rub,
       round(100 * (value / (select s4_ordered_active from m) - 1), 1) as pct_vs_clean_ordered
from (
    select 1 as ord, '1. Сырая выгрузка (дубли, версии, отмены)' as step, s1_raw_all as value from s
    union all select 2, '2. − полные дубли строк', s2_no_dups from s
    union all select 3, '3. − старые версии строк', s3_last_version from m
    union all select 4, '4. − отменённые строки = ЗАКАЗАНО (база)', s4_ordered_active from m
    union all select 5, '4a. заказано, inner join на справочник номенклатуры', s4a_ordered_known_items from m
    union all select 6, '4b. заказано, inner join на курсы без выходных', s4b_ordered_no_weekend_fx from m
    union all select 7, '4c. заказано, если цены «CNY» на самом деле в USD', s4c_ordered_cny_as_usd from m
    union all select 8, '5. ПРИНЯТО, кроме полностью отбракованного, по дате приёмки (вкл. отменённые строки)', s5_received_not_rejected from f
    union all select 9, '5a. то же, только активные строки', s5a_received_active_only from f
    union all select 10, '5b. ПРИНЯТО только accepted (частичный брак не засчитан)', s5b_received_accepted_only from f
) x
order by ord;
