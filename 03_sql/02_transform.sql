-- =====================================================================
-- 02_transform.sql — raw → dm. Каждое решение по качеству данных прокомментировано.
-- Дата «сегодня» по легенде: 2026-08-12. Нигде не используем current_date:
-- в реальности сейчас другая дата, и с ней все «последние полные месяцы» уехали бы.
-- =====================================================================

-- ---------- ЕИ ----------
insert into dm.dim_uom
select uom_code, uom_name, base_uom, factor_to_base::numeric
from raw.uom;

-- ---------- Мастер-карта поставщиков ----------
-- Дубли по ИНН: 8 ИНН имеют по два кода (S10xx и S1121..S1128).
-- Мастер = код с самой ранней valid_from (у старых кодов история с 2024-01-01,
-- у дублей — с середины 2024, т.е. карточки заведены позже, вероятно после миграции).
insert into dm.map_supplier_master
with first_ver as (
    select supplier_id, inn, min(valid_from::date) as first_valid_from
    from raw.suppliers
    group by supplier_id, inn
),
ranked as (
    select supplier_id, inn,
           first_value(supplier_id) over (partition by inn order by first_valid_from, supplier_id) as master_id
    from first_ver
)
select supplier_id,
       master_id,
       inn,
       supplier_id <> master_id                                  as is_duplicate,
       case when supplier_id = master_id then 'self' else 'inn' end as match_rule
from ranked;

-- ---------- Поставщик SCD2 ----------
-- Берём историю версий только мастер-кода. Атрибуты дубля (другое имя, «Москва», другой класс)
-- в аналитику не идут: класс надёжности — один на юрлицо. Конфликты классов master vs дубль
-- (например, S1050=A и S1128=C) вынесены в вопросы заказчику.
insert into dm.dim_supplier (master_supplier_id, inn, supplier_name, region, reliability_class, valid_from, valid_to, is_current)
select s.supplier_id, s.inn, s.supplier_name, s.region, s.reliability_class,
       s.valid_from::date, s.valid_to::date, s.is_current = '1'
from raw.suppliers s
join dm.map_supplier_master m on m.supplier_id = s.supplier_id and not m.is_duplicate;

-- ---------- Номенклатура (+ заглушки для неизвестных позиций) ----------
-- Внимание: uom_code карточки — не обязательно базовая ЕИ (бывает PACK24, TON).
-- Совместимость ЕИ строки проверяем по base_uom, а не по коду.
insert into dm.dim_item
select i.item_id, i.item_name, i.category, i.category_reported, i.uom_code, u.base_uom, true
from raw.items i
join raw.uom u on u.uom_code = i.uom_code;

-- 40 позиций есть в заказах, но нет в справочнике (~5% оборота).
-- Не выкидываем: заводим заглушку, категория «(нет в справочнике)».
insert into dm.dim_item
select distinct l.item_id, 'Позиция ' || l.item_id || ' (нет в справочнике)', '(нет в справочнике)', null, null, null, false
from raw.po_lines l
where not exists (select 1 from raw.items i where i.item_id = l.item_id);

-- ---------- Курсы: протяжка на выходные ----------
-- ЦБ не публикует курс на выходные → в выгрузке нет сб/вс. Заказов в валюте (со строками) в выходные — 199.
-- Inner join с курсами молча выкинул бы их из оборота. Протягиваем последний известный курс.
insert into dm.fx_rate_daily
select d::date, c.currency, f.rate_to_rub::numeric, f.rate_date::date
from generate_series('2024-01-01'::date, '2026-08-12'::date, interval '1 day') d
cross join (select distinct currency from raw.fx_rates) c
cross join lateral (
    select rate_to_rub, rate_date
    from raw.fx_rates f
    where f.currency = c.currency and f.rate_date::date <= d::date
    order by f.rate_date::date desc
    limit 1
) f
union all
select d::date, 'RUB', 1, d::date
from generate_series('2024-01-01'::date, '2026-08-12'::date, interval '1 day') d;

-- ---------- Факт строк заказа ----------
insert into dm.fct_po_line
with dedup as (
    -- 1) Точные дубли строк (1 591 лишняя строка) — артефакт выгрузки.
    select distinct order_id, line_no::int as line_no, item_id, qty::numeric as qty, price::numeric as price,
           plan_price::numeric as plan_price, uom_code, planned_delivery_date::date as planned_delivery_date,
           status, updated_at::timestamp as updated_at
    from raw.po_lines
),
versioned as (
    -- 2) Версии строки (805 строк с двумя разными состояниями): берём последнюю по updated_at.
    select d.*,
           row_number() over (partition by order_id, line_no order by updated_at desc) as rn,
           count(*)     over (partition by order_id, line_no)                         as version_cnt
    from dedup d
)
select
    v.order_id,
    v.line_no,
    h.supplier_id,
    m.master_supplier_id,
    ds.supplier_sk,
    v.item_id,
    h.order_dttm_msk::timestamp,
    h.order_dttm_msk::date,
    h.order_type,
    h.delivery_city,
    h.currency,
    fx.rate_to_rub,
    v.uom_code,
    v.qty,
    case when u.base_uom = i.base_uom then v.qty * u.factor_to_base end            as qty_base,
    v.price,
    v.plan_price,
    round(v.qty * v.price * fx.rate_to_rub, 2)                                      as amount_rub,
    round(v.qty * v.plan_price * fx.rate_to_rub, 2)                                 as plan_amount_rub,
    case when u.base_uom = i.base_uom then v.price * fx.rate_to_rub / u.factor_to_base end as price_per_base_rub,
    v.planned_delivery_date,
    v.status,
    v.updated_at,
    v.version_cnt,
    not i.is_in_catalog                                                             as dq_item_unknown,
    -- ЕИ строки нельзя привести к базовой ЕИ позиции (кг ↔ шт ↔ м). Для неизвестных позиций базы нет вовсе.
    coalesce(u.base_uom <> i.base_uom, true)                                         as dq_uom_incompatible,
    h.currency = 'CNY'                                                              as dq_fx_suspect,
    not exists (select 1 from raw.suppliers s
                where s.supplier_id = h.supplier_id
                  and h.order_dttm_msk::date between s.valid_from::date and s.valid_to::date) as dq_supplier_scd_gap
from versioned v
join raw.po_headers h            on h.order_id = v.order_id
join dm.map_supplier_master m    on m.supplier_id = h.supplier_id
join dm.dim_item i               on i.item_id = v.item_id            -- inner безопасен: заглушки уже заведены
join dm.dim_uom u                on u.uom_code = v.uom_code
join dm.fx_rate_daily fx         on fx.currency = h.currency and fx.rate_date = h.order_dttm_msk::date
left join dm.dim_supplier ds     on ds.master_supplier_id = m.master_supplier_id
                                and h.order_dttm_msk::date between ds.valid_from and ds.valid_to
where v.rn = 1;

-- ---------- Факт приёмки ----------
-- received_at_utc — UTC. Плановая дата поставки — дата МСК. Сравнивать можно только в одной зоне:
-- 7 914 приёмок попадают на другую календарную дату при переводе в МСК, 730 из них из «вовремя» становятся «опоздал».
insert into dm.fct_receipt
select r.receipt_id,
       r.order_id,
       r.line_no::int,
       r.received_at_utc::timestamptz,
       (r.received_at_utc::timestamptz at time zone 'Europe/Moscow')::date,
       r.qty_received::numeric,
       r.quality_status,
       r.warehouse_code,
       l.status = 'cancelled',
       (r.received_at_utc::timestamptz at time zone 'Europe/Moscow') < l.order_dttm_msk
from raw.receipts r
join dm.fct_po_line l on l.order_id = r.order_id and l.line_no = r.line_no::int;

-- ---------- Витрина OTIF ----------
-- Определение (см. 02_model.md, матрица метрик):
--   знаменатель — активные строки заказа с плановой датой <= as_of_date (2026-08-12);
--   строка OTIF, если количество со статусом 'accepted', принятое не позже плановой даты (дата МСК),
--   >= заказанного количества (последняя версия строки). Ранняя поставка и перепоставка не штрафуются.
--   partially_rejected не засчитываем: в событии нет принятого количества (запросили у WMS qty_accepted).
insert into dm.mart_otif_line
with agg as (
    select l.order_id, l.line_no, l.master_supplier_id, l.planned_delivery_date, l.qty,
           coalesce(sum(r.qty_received) filter (where r.quality_status = 'accepted'
                                                  and r.received_date_msk <= l.planned_delivery_date), 0) as qty_acc_ot,
           coalesce(sum(r.qty_received), 0)                                                              as qty_total,
           coalesce(sum(r.qty_received) filter (where r.quality_status = 'accepted'), 0)                 as qty_acc,
           min(r.received_date_msk) as first_d,
           max(r.received_date_msk) as last_d
    from dm.fct_po_line l
    left join dm.fct_receipt r on r.order_id = l.order_id and r.line_no = l.line_no
                              and r.received_date_msk <= date '2026-08-12'   -- приёмки «из будущего» (7 шт. после даты выгрузки) не учитываем
    where l.status = 'active'
      and l.planned_delivery_date <= date '2026-08-12'
    group by l.order_id, l.line_no, l.master_supplier_id, l.planned_delivery_date, l.qty
)
select order_id, line_no, master_supplier_id, planned_delivery_date, qty,
       qty_acc_ot, qty_total, first_d, last_d,
       qty_total > 0,
       coalesce(last_d <= planned_delivery_date, false),   -- нет приёмки = не вовремя (а не NULL!)
       qty_acc >= qty,
       qty_acc_ot >= qty,
       date '2026-08-12'
from agg;

analyze;
