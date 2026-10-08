-- =====================================================================
-- Q1. OTIF по поставщикам за последние 6 ПОЛНЫХ месяцев
-- =====================================================================
-- Определение OTIF (из 02_model.md):
--   Единица — строка заказа (order_id, line_no), последняя версия, статус active.
--   Строка попадает в месяц по ПЛАНОВОЙ дате поставки (обещание поставщика, а не дата заказа).
--   Строка = OTIF, если сумма qty_received со статусом 'accepted', принятая с датой МСК <= плановой даты,
--   >= заказанного количества. Нет приёмки к плановой дате = не OTIF.
--   OTIF поставщика = доля OTIF-строк (не взвешиваем по сумме: срыв дешёвой позиции тоже останавливает склад).
-- «Поставка» для порога >= 20 = строка заказа с плановой датой в периоде.
-- Поставщик = мастер-поставщик (дубли по ИНН склеены).
-- Класс надёжности = версия SCD2 на последний день периода.
-- Сегодня по легенде 2026-08-12 → полные месяцы: 2026-02 … 2026-07. Август неполный — не берём.
-- Ранг и динамика считаются по НЕокруглённым значениям (округление до 0,1 создаёт ложные ничьи).
-- otif_ci_low_pct — нижняя граница 95% доверительного интервала (Уилсон): при ~80 поставках
-- на поставщика ±11 п.п. — это шум. На пилотной выгрузке разброс OTIF между поставщиками
-- статистически неотличим от случайного (χ² = 135,8 при 119 ст. св., p ≈ 0,14),
-- поэтому рейтинг показываем вместе с интервалом, а не голым местом.
-- =====================================================================
with params as (
    select date '2026-08-12'                                             as as_of_date,
           (date_trunc('month', date '2026-08-12') - interval '6 months')::date as period_start,  -- 2026-02-01
           date_trunc('month', date '2026-08-12')::date                  as period_end_excl      -- 2026-08-01
),
lines as (
    select o.master_supplier_id,
           date_trunc('month', o.planned_delivery_date)::date as month,
           o.is_otif
    from dm.mart_otif_line o
    cross join params p
    where o.planned_delivery_date >= p.period_start
      and o.planned_delivery_date <  p.period_end_excl
),
eligible as (
    -- Порог считается за весь период, а не помесячно
    select master_supplier_id,
           count(*)                                   as deliveries,
           sum(is_otif::int)                          as otif_lines,
           avg(is_otif::int)                          as otif_period      -- доля 0..1, без округления
    from lines
    group by master_supplier_id
    having count(*) >= 20
),
months as (
    select generate_series(p.period_start, p.period_end_excl - 1, interval '1 month')::date as month
    from params p
),
monthly as (
    -- Сетка поставщик × месяц: если в каком-то месяце не было поставок, LAG не должен
    -- «перепрыгнуть» через пустой месяц и сравнить июль с маем.
    select e.master_supplier_id,
           m.month,
           count(l.is_otif)                                        as deliveries_month,
           avg(l.is_otif::int)                                     as otif_month      -- NULL, если поставок в месяце нет
    from eligible e
    cross join months m
    left join lines l on l.master_supplier_id = e.master_supplier_id and l.month = m.month
    group by e.master_supplier_id, m.month
),
supplier_attr as (
    -- Атрибуты на конец периода (2026-07-31), а не «текущие»: отчёт должен быть воспроизводим
    select s.master_supplier_id, s.supplier_name, s.reliability_class
    from dm.dim_supplier s
    cross join params p
    where p.period_end_excl - 1 between s.valid_from and s.valid_to
),
ranked as (
    select e.master_supplier_id,
           a.supplier_name,
           a.reliability_class,
           e.deliveries,
           e.otif_period,
           -- нижняя граница Уилсона, z = 1.96
           (e.otif_period + 1.96^2 / (2 * e.deliveries)
             - 1.96 * sqrt(e.otif_period * (1 - e.otif_period) / e.deliveries + 1.96^2 / (4 * e.deliveries^2)))
             / (1 + 1.96^2 / e.deliveries)                                               as otif_ci_low,
           rank() over (partition by a.reliability_class order by e.otif_period desc) as rank_in_class,
           count(*) over (partition by a.reliability_class)                              as suppliers_in_class
    from eligible e
    join supplier_attr a using (master_supplier_id)
)
select r.reliability_class,
       r.rank_in_class,
       r.suppliers_in_class,
       r.master_supplier_id,
       r.supplier_name,
       r.deliveries                                  as deliveries_period,
       round(100 * r.otif_period, 1)                 as otif_period_pct,
       round((100 * r.otif_ci_low)::numeric, 1)      as otif_ci_low_pct,
       to_char(m.month, 'YYYY-MM')                   as month,
       m.deliveries_month,
       round(100 * m.otif_month, 1)                  as otif_month_pct,
       -- динамика месяц к месяцу в п.п., считаем по точным долям, округляем только результат
       round(100 * (m.otif_month - lag(m.otif_month) over (partition by m.master_supplier_id order by m.month)), 1) as mom_delta_pp
from ranked r
join monthly m using (master_supplier_id)
order by r.reliability_class, r.rank_in_class, r.master_supplier_id, m.month;
