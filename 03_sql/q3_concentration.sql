-- =====================================================================
-- Q3. Концентрация поставщиков по категориям
-- =====================================================================
-- Период: последние 12 полных месяцев (2025-08-01 … 2026-07-31) по дате заказа — в задании период
--   не задан; 12 месяцев сглаживают сезонность. Меняется в params.
-- Оборот = сумма активных строк заказа (последняя версия), в рублях по курсу на дату заказа.
--   Заказы в CNY входят по курсу ЦБ, как в 1С (их доля мала; их проблема — в ценах, см. Q2).
-- Поставщик = мастер-поставщик: без склейки по ИНН поставщик с двумя кодами делит долю пополам
--   и может «выпасть» из ядра 80%.
-- Позиции не из справочника — отдельная категория «(нет в справочнике)», чтобы сумма сходилась с общим оборотом.
-- «Сколько поставщиков дают 80%» = число поставщиков, нужных, чтобы ДОСТИЧЬ 80%:
--   включаем того, на ком накопленная доля переходит через 80% (условие по доле ДО него < 80%).
--   Частая ошибка — считать строки с cum_share <= 80%: тогда «пересекающий» поставщик не учитывается.
-- =====================================================================
with params as (
    select date '2025-08-01' as p_start,
           date '2026-08-01' as p_end_excl
),
turnover as (
    -- зерно: категория × поставщик
    select i.category,
           l.master_supplier_id,
           sum(l.amount_rub) as amount_rub
    from dm.fct_po_line l
    join dm.dim_item i on i.item_id = l.item_id
    cross join params p
    where l.status = 'active'
      and l.order_date >= p.p_start and l.order_date < p.p_end_excl
    group by i.category, l.master_supplier_id
),
shares as (
    select t.*,
           t.amount_rub / sum(t.amount_rub) over (partition by t.category)                 as share,
           row_number() over (partition by t.category order by t.amount_rub desc, t.master_supplier_id) as rn,
           -- Явно ROWS, а не RANGE (по умолчанию). С уникальным тай-брейкером ниже результаты совпадают, но если его
           -- убрать, RANGE отдаст поставщикам с равной суммой одинаковую накопленную долю. ROWS фиксирует намерение.
           -- master_supplier_id — тай-брейкер, чтобы порядок был детерминированным.
           sum(t.amount_rub) over (partition by t.category
                                   order by t.amount_rub desc, t.master_supplier_id
                                   rows between unbounded preceding and current row)
             / sum(t.amount_rub) over (partition by t.category)                           as cum_share
    from turnover t
),
flagged as (
    select s.*,
           (s.cum_share - s.share) < 0.8 as in_core_80   -- доля ДО этого поставщика ещё не достигла 80%
    from shares s
)
select f.category,
       f.rn                                                            as rank_in_category,
       f.master_supplier_id                                            as supplier_id,
       d.supplier_name,
       round(f.amount_rub, 0)                                          as amount_rub,
       round(100 * f.share, 2)                                         as share_pct,
       round(100 * f.cum_share, 2)                                     as cum_share_pct,
       f.in_core_80,
       count(*) filter (where f.in_core_80) over (partition by f.category) as suppliers_for_80pct,
       count(*)                            over (partition by f.category) as suppliers_total,
       round(sum(f.amount_rub) over (partition by f.category) / 1e6, 1)   as category_turnover_mln_rub
from flagged f
join dm.dim_supplier d on d.master_supplier_id = f.master_supplier_id and d.is_current
order by f.category, f.rn;
