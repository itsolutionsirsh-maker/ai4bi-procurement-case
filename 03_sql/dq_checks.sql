-- =====================================================================
-- dq_checks.sql — как обнаружены дефекты данных (02_model.md, раздел 6).
-- Каждая проверка — по сырому слою raw, чтобы было видно масштаб «как есть».
-- В пайплайне эти же проверки — dbt-тесты / Great Expectations на слое stg.
-- =====================================================================
with
c1 as (  -- Дубли поставщиков: один ИНН — несколько кодов
    select count(*) as n from (select inn from raw.suppliers group by inn having count(distinct supplier_id) > 1) x
),
c2 as (  -- Полные дубли строк заказа
    select count(*) - count(distinct (order_id, line_no, item_id, qty, price, plan_price, uom_code,
                                      planned_delivery_date, status, updated_at)) as n
    from raw.po_lines
),
c3 as (  -- Строки заказа с несколькими разными версиями
    select count(*) as n from (
        select order_id, line_no from (select distinct * from raw.po_lines) d
        group by order_id, line_no having count(*) > 1) x
),
c3b as ( -- Из них: приёмка совпадает с ПЕРВОЙ версией количества, а не с последней
    select count(*) as n from (
        select d.order_id, d.line_no,
               (array_agg(d.qty::numeric order by d.updated_at))[1] as qty_first
        from (select distinct * from raw.po_lines) d
        group by d.order_id, d.line_no having count(*) > 1) v
    join (select order_id, line_no, sum(qty_received::numeric) as q from raw.receipts group by 1, 2) r
      on r.order_id = v.order_id and r.line_no = v.line_no
    where r.q = v.qty_first
),
c4 as (  -- Позиции в заказах, которых нет в справочнике
    select count(distinct item_id) as items, count(*) as n
    from raw.po_lines l where not exists (select 1 from raw.items i where i.item_id = l.item_id)
),
c5 as (  -- Приёмки, у которых дата по UTC и по МСК разная, и из них «вовремя» → «опоздание»
    select count(*) filter (where (r.received_at_utc::timestamptz at time zone 'UTC')::date
                               <> (r.received_at_utc::timestamptz at time zone 'Europe/Moscow')::date) as n_shift,
           count(*) filter (where (r.received_at_utc::timestamptz at time zone 'UTC')::date <= l.planned_delivery_date::date
                              and (r.received_at_utc::timestamptz at time zone 'Europe/Moscow')::date > l.planned_delivery_date::date) as n_flip
    from raw.receipts r
    join (select distinct order_id, line_no, planned_delivery_date from raw.po_lines) l
      on l.order_id = r.order_id and l.line_no = r.line_no
),
c6 as (  -- Валютные заказы в дни без курса ЦБ (выходные)
    select count(*) as n from raw.po_headers h
    where h.currency <> 'RUB'
      and not exists (select 1 from raw.fx_rates f where f.currency = h.currency and f.rate_date::date = h.order_dttm_msk::date)
      and exists (select 1 from raw.po_lines l where l.order_id = h.order_id)   -- только заказы со строками (см. D17)
),
c7 as (  -- CNY: цена после пересчёта в рубли / медиана рублёвой цены той же позиции в той же ЕИ
    select h.currency,
           percentile_cont(0.5) within group (order by l.price::numeric * f.rate_to_rub::numeric / rub.med) as ratio
    from raw.po_lines l
    join raw.po_headers h using (order_id)
    join lateral (select rate_to_rub from raw.fx_rates f
                  where f.currency = h.currency and f.rate_date::date <= h.order_dttm_msk::date
                  order by f.rate_date desc limit 1) f on true
    join (select l2.item_id, l2.uom_code, percentile_cont(0.5) within group (order by l2.price::numeric) as med
          from raw.po_lines l2 join raw.po_headers h2 using (order_id)
          where h2.currency = 'RUB' group by 1, 2) rub on rub.item_id = l.item_id and rub.uom_code = l.uom_code
    where h.currency <> 'RUB'
    group by h.currency
),
c8 as (  -- ЕИ строки несовместима с базовой ЕИ карточки
    select count(*) as n
    from (select distinct order_id, line_no, item_id, uom_code from raw.po_lines) l
    join raw.items i using (item_id)
    join raw.uom ul on ul.uom_code = l.uom_code
    join raw.uom ui on ui.uom_code = i.uom_code
    where ul.base_uom <> ui.base_uom
),
c9 as (  -- Цена не зависит от упаковки: медиана рублёвой цены по ЕИ строки
    select string_agg(uom_code || '=' || round(med) , ', ' order by factor) as s
    from (select l.uom_code, u.factor_to_base::numeric as factor,
                 percentile_cont(0.5) within group (order by l.price::numeric) as med
          from raw.po_lines l join raw.po_headers h using (order_id) join raw.uom u using (uom_code)
          where h.currency = 'RUB' group by 1, 2) x
),
c10 as ( -- Приёмка по отменённым строкам (последняя версия = cancelled)
    select count(*) as n
    from raw.receipts r
    join (select distinct on (order_id, line_no) order_id, line_no, status
          from raw.po_lines order by order_id, line_no, updated_at desc) l
      on l.order_id = r.order_id and l.line_no = r.line_no
    where l.status = 'cancelled'
),
c11 as ( -- Приёмка раньше создания заказа
    select count(*) as n
    from raw.receipts r join raw.po_headers h using (order_id)
    where (r.received_at_utc::timestamptz at time zone 'Europe/Moscow') < h.order_dttm_msk::timestamp
),
c12 as ( -- Расхождение category и category_reported
    select count(*) as n from raw.items where category <> category_reported
),
c13 as ( -- Заказы по коду поставщика до начала действия его карточки (SCD2 as-of join не найдёт версию)
    select count(*) as n from raw.po_headers h
    where not exists (select 1 from raw.suppliers s where s.supplier_id = h.supplier_id
                      and h.order_dttm_msk::date between s.valid_from::date and s.valid_to::date)
      and exists (select 1 from raw.po_lines l where l.order_id = h.order_id)   -- только заказы со строками (см. D17)
),
c14 as ( -- partially_rejected без принятого количества
    select count(*) as n from raw.receipts where quality_status = 'partially_rejected'
),
c15 as ( -- Записи «из будущего»: изменения строк и приёмки после даты выгрузки 12.08.2026
    select (select count(*) from (select distinct * from raw.po_lines where updated_at::timestamp >= '2026-08-13') d) as lines_after,
           (select max(updated_at) from raw.po_lines)                                      as max_upd,
           (select count(*) from raw.receipts
             where (received_at_utc::timestamptz at time zone 'Europe/Moscow')::date > '2026-08-12') as rcpt_after
),
c17 as ( -- Шапки заказов без единой строки (и без приёмок)
    select count(*) filter (where not exists (select 1 from raw.po_lines l where l.order_id = h.order_id)) as n,
           count(*) as total
    from raw.po_headers h
),
c18 as ( -- Дробное количество в штучных ЕИ (PCS и упаковки)
    select round(100.0 * count(*) filter (where qty::numeric <> trunc(qty::numeric)) / count(*), 1) as pct
    from raw.po_lines where uom_code in ('PCS', 'PACK6', 'PACK12', 'PACK24')
),
c16 as ( -- Цена не зависит от позиции: коэф. вариации цены внутри позиции vs по всему массиву (RUB)
    select round(avg(cv_item)::numeric, 2) as cv_within_item,
           (select round((stddev(price::numeric) / avg(price::numeric))::numeric, 2)
              from raw.po_lines l join raw.po_headers h using (order_id) where h.currency = 'RUB') as cv_overall
    from (select l.item_id, stddev(l.price::numeric) / avg(l.price::numeric) as cv_item
          from raw.po_lines l join raw.po_headers h using (order_id)
          where h.currency = 'RUB' group by l.item_id having count(*) >= 10) x
)
select 'D1 Дубли поставщиков по ИНН (ИНН с >1 кодом)'               as check_name, (select n from c1)::text as result
union all select 'D2 Полные дубли строк заказа',                                  (select n from c2)::text
union all select 'D3 Строки заказа с 2 версиями (разные qty/price)',              (select n from c3)::text
union all select 'D3b …из них приёмка = qty ПЕРВОЙ версии',                       (select n from c3b)::text
union all select 'D4 Позиций не в справочнике / строк с ними',                    (select items || ' / ' || n from c4)
union all select 'D5 Приёмок со сдвигом даты UTC→МСК / из них вовремя→опоздание', (select n_shift || ' / ' || n_flip from c5)
union all select 'D6 Валютных заказов в дни без курса ЦБ',                        (select n from c6)::text
union all select 'D7 Цена в валюте×курс / рублёвая медиана (норма ≈1)',          (select string_agg(currency || '=' || round(ratio::numeric, 3), ', ') from c7)
union all select 'D8 Строк с ЕИ, несовместимой с карточкой',                      (select n from c8)::text
union all select 'D9 Медиана цены (RUB) по ЕИ строки',                            (select s from c9)
union all select 'D10 Приёмок по отменённым строкам',                             (select n from c10)::text
union all select 'D11 Приёмок раньше создания заказа',                            (select n from c11)::text
union all select 'D12 Позиций с category <> category_reported',                   (select n from c12)::text
union all select 'D13 Заказов вне периода действия карточки поставщика',          (select n from c13)::text
union all select 'D14 Приёмок partially_rejected без принятого кол-ва',           (select n from c14)::text
union all select 'D15 Строк с updated_at после 12.08 / max updated_at / приёмок после 12.08 (МСК)',
                                                                                   (select lines_after || ' / ' || max_upd || ' / ' || rcpt_after from c15)
union all select 'D16 Коэф. вариации цены внутри позиции / по всем позициям',     (select cv_within_item || ' / ' || cv_overall from c16)
union all select 'D17 Шапок заказов без строк / всего шапок',                    (select n || ' / ' || total from c17)
union all select 'D8b % строк в штучных ЕИ с дробным количеством',               (select pct::text from c18);
