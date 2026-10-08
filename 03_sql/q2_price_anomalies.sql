-- =====================================================================
-- Q2. Ценовые аномалии за последний полный квартал (2026-Q2: 01.04–30.06.2026)
-- =====================================================================
-- Логика:
--   1. Цена за базовую ЕИ в рублях = price × курс ЦБ на дату заказа / factor_to_base(ЕИ строки).
--   2. Средневзвешенная цена поставщика = sum(сумма, руб.) / sum(кол-во в базовых ЕИ).
--      Не avg(price): средняя по строкам дала бы строке на 1 кг тот же вес, что строке на 5 тонн.
--   3. Медиана по позиции у ДРУГИХ поставщиков = медиана их средневзвешенных цен
--      (одна цена на поставщика, чтобы частый поставщик не перетягивал медиану).
--      Требуем >= 2 других поставщиков, иначе «медиана» = цена одного конкурента.
--   4. |отклонение| > 15%. Сортировка по денежному эффекту = (наша цена − медиана) × объём в базовых ЕИ:
--      +15% на закупке за 10 млн важнее +80% на закупке за 20 тыс.
--      Переплата (эффект > 0) всегда меньше суммы закупки. «Экономия» (эффект < 0) может быть больше неё:
--      цена на 95% ниже медианы = эффект в 19 раз больше закупки. Такие строки скорее ошибка данных, чем удача.
--      Для отчёта Смирнову «где переплачиваем» — фильтр money_effect_rub > 0 (одна строка в конце).
--
-- ОГРАНИЧЕНИЕ НА ЭТОЙ ВЫГРУЗКЕ: зависимости цены строки ни от ЕИ, ни от позиции не видно
-- (разброс цены внутри одной позиции такой же, как по всем позициям, 50…40 000 ₽),
-- а в квартале у поставщика по позиции почти всегда одна строка (our_lines).
-- Запрос методически корректен, но на этих данных выдаёт сигналы для расследования, а не экономию. Заказчику не показываю
-- до ответа 1С по вопросам 4–5 (01_discovery.md).
--
-- ВАЖНОЕ РЕШЕНИЕ — с кем сравниваем (ключ сравнения):
--   По заданию сравнение «за базовую единицу» внутри позиции. Первая версия запроса так и делала:
--   (item_id, base_uom). Результат — топ-15 из «−100%, эффект −6 млрд ₽» на закупках в 0,4 млн:
--   в этой выгрузке зависимости цены от упаковки не видно (медиана цены за тонну ≈ за килограмм ≈ 20 тыс. ₽,
--   за PACK24 ≈ за штуку). Деление на factor 1000/50/24 рождает фиктивные аномалии.
--   Поэтому сравниваем позицию в ОДНОЙ И ТОЙ ЖЕ ЕИ закупки: ключ (item_id, uom_code).
--   Цена всё равно выводится за базовую ЕИ, а % отклонения не зависит от того, верен ли коэффициент.
--   Когда 1С подтвердит, что ЕИ и цена в строке согласованы, переключение на (item_id, base_uom) —
--   одна строка в CTE lines: `l.uom_code,` → `u.base_uom as uom_code,` (дальше ключ [KEY] работает как есть).
--
-- Исключения (02_model.md, «Что не так с данными»):
--   - заказы в CNY (dq_fx_suspect): после пересчёта по курсу ЦБ цены в 7 раз ниже рынка;
--     до подтверждения валюты/цены из 1С в ценовом сравнении не участвуют.
-- =====================================================================
with params as (
    select date '2026-04-01' as q_start,       -- последний полный квартал при дате легенды 2026-08-12
           date '2026-07-01' as q_end_excl
),
lines as (
    select l.item_id,
           l.uom_code,
           u.base_uom,
           l.master_supplier_id,
           l.qty * u.factor_to_base  as qty_base,   -- в базовой ЕИ своей упаковки (TON→KG, PACK24→PCS)
           l.amount_rub
    from dm.fct_po_line l
    join dm.dim_uom u on u.uom_code = l.uom_code
    cross join params p
    where l.status = 'active'
      and l.order_date >= p.q_start and l.order_date < p.q_end_excl
      and not l.dq_fx_suspect
),
supplier_price as (
    -- зерно: позиция × ЕИ закупки × поставщик за квартал
    select item_id, uom_code, base_uom, master_supplier_id,
           sum(amount_rub)                 as amount_rub,
           sum(qty_base)                   as qty_base,
           sum(amount_rub) / sum(qty_base) as wavg_price_base_rub,
           count(*)                        as our_lines
    from lines
    group by item_id, uom_code, base_uom, master_supplier_id          -- [KEY]
),
with_median as (
    -- «медиана у других»: self-join без самого себя.
    -- percentile_cont в PostgreSQL не бывает оконной, поэтому join + group by.
    select a.item_id, a.uom_code, a.base_uom, a.master_supplier_id,
           a.amount_rub, a.qty_base, a.wavg_price_base_rub, a.our_lines,
           percentile_cont(0.5) within group (order by b.wavg_price_base_rub) as median_others,
           count(*)                                                          as other_suppliers
    from supplier_price a
    join supplier_price b
      on b.item_id = a.item_id and b.uom_code = a.uom_code                 -- [KEY]
     and b.master_supplier_id <> a.master_supplier_id
    group by a.item_id, a.uom_code, a.base_uom, a.master_supplier_id,
             a.amount_rub, a.qty_base, a.wavg_price_base_rub, a.our_lines
    having count(*) >= 2
),
anomalies as (
    select m.*,
           (m.wavg_price_base_rub / m.median_others - 1) * 100     as deviation_pct,
           (m.wavg_price_base_rub - m.median_others) * m.qty_base  as money_effect_rub
    from with_median m
    where abs(m.wavg_price_base_rub / m.median_others - 1) > 0.15
)
select a.item_id,
       i.item_name,
       i.category,
       a.master_supplier_id                        as supplier_id,
       s.supplier_name,
       a.uom_code                                  as purchase_uom,
       a.base_uom,
       round(a.wavg_price_base_rub::numeric, 2)    as our_price_rub_per_base,
       round(a.median_others::numeric, 2)          as median_others_rub_per_base,
       a.our_lines,
       a.other_suppliers,
       round(a.deviation_pct::numeric, 1)          as deviation_pct,
       round(a.amount_rub, 0)                      as purchase_amount_rub,
       round(a.money_effect_rub::numeric, 0)       as money_effect_rub   -- >0 переплата, <0 дешевле медианы
from anomalies a
join dm.dim_item i     on i.item_id = a.item_id
cross join params p
-- имя поставщика — версия на конец квартала (как в Q1: отчёт воспроизводим)
join dm.dim_supplier s on s.master_supplier_id = a.master_supplier_id
                      and p.q_end_excl - 1 between s.valid_from and s.valid_to
-- where a.money_effect_rub > 0          -- вариант «только переплаты» для Смирнова
order by abs(a.money_effect_rub) desc
limit 15;
