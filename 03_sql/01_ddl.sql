-- =====================================================================
-- 01_ddl.sql — целевая модель (PostgreSQL 16)
-- Слои: raw (as-is, всё text) → stg (типизация, дедуп, флаги качества) → dm (звезда + витрины)
-- Здесь — только dm. stg-логика в 02_transform.sql (в проде это были бы dbt-модели).
-- =====================================================================
drop schema if exists dm cascade;
create schema dm;

-- ---------------------------------------------------------------------
-- Справочник ЕИ. Зерно: одна строка = одна единица измерения.
-- ---------------------------------------------------------------------
create table dm.dim_uom (
    uom_code        text primary key,
    uom_name        text not null,
    base_uom        text not null,          -- PCS / KG / M
    factor_to_base  numeric(12,4) not null check (factor_to_base > 0)
);

-- ---------------------------------------------------------------------
-- Мастер-карта поставщиков (golden record).
-- Зерно: одна строка = один supplier_id из 1С → его мастер-поставщик.
-- Дубли склеиваем по ИНН; мастер = код с самой ранней историей (старый код S10xx).
-- ---------------------------------------------------------------------
create table dm.map_supplier_master (
    supplier_id         text primary key,
    master_supplier_id  text not null,
    inn                 text not null,
    is_duplicate        boolean not null,   -- true = код-дубль, не мастер
    match_rule          text not null       -- 'self' | 'inn'
);
create index on dm.map_supplier_master (master_supplier_id);

-- ---------------------------------------------------------------------
-- Поставщик, SCD Type 2.
-- Зерно: одна строка = одна версия атрибутов мастер-поставщика за интервал [valid_from, valid_to].
-- ---------------------------------------------------------------------
create table dm.dim_supplier (
    supplier_sk        bigint generated always as identity primary key,
    master_supplier_id text not null,
    inn                text not null,
    supplier_name      text not null,
    region             text,
    reliability_class  char(1) not null check (reliability_class in ('A','B','C')),
    valid_from         date not null,
    valid_to           date not null,      -- 9999-12-31 для текущей версии
    is_current         boolean not null,
    unique (master_supplier_id, valid_from),
    check (valid_from <= valid_to)
);
create index on dm.dim_supplier (master_supplier_id, valid_from, valid_to);
-- Не больше одной текущей версии на поставщика:
create unique index on dm.dim_supplier (master_supplier_id) where is_current;

-- ---------------------------------------------------------------------
-- Номенклатура, SCD1 (истории в источнике нет).
-- Зерно: одна строка = одна позиция. Позиции, которых нет в справочнике 1С, получают
-- строку-заглушку (is_in_catalog = false), чтобы факты не терялись на JOIN.
-- ---------------------------------------------------------------------
create table dm.dim_item (
    item_id            text primary key,
    item_name          text not null,
    category           text not null,      -- '(нет в справочнике)' для заглушек
    category_reported  text,               -- второе поле из 1С, расходится в 33 позициях — храним для сверки
    uom_code           text references dm.dim_uom(uom_code),  -- ЕИ из карточки (может быть упаковкой: PACK24, TON)
    base_uom           text,                                  -- базовая ЕИ карточки (PCS/KG/M) — с ней сверяем ЕИ строки
    is_in_catalog      boolean not null
);
create index on dm.dim_item (category);

-- ---------------------------------------------------------------------
-- Курсы на каждый календарный день (протяжка последнего курса ЦБ на выходные/праздники).
-- Зерно: одна строка = валюта × календарный день. RUB = 1 хранится явно, чтобы JOIN был inner.
-- ---------------------------------------------------------------------
create table dm.fx_rate_daily (
    rate_date        date not null,
    currency         char(3) not null,
    rate_to_rub      numeric(18,6) not null check (rate_to_rub > 0),
    source_rate_date date not null,        -- дата фактической котировки ЦБ (для аудита протяжки)
    primary key (currency, rate_date)
);

-- ---------------------------------------------------------------------
-- Факт: строка заказа поставщику (текущая версия).
-- Зерно: одна строка = одна строка заказа (order_id, line_no) в ПОСЛЕДНЕЙ версии по updated_at.
-- Отменённые строки остаются (status = 'cancelled'), фильтруются в метриках.
-- ---------------------------------------------------------------------
create table dm.fct_po_line (
    order_id              text not null,
    line_no               int  not null,
    supplier_id           text not null,             -- как в 1С (для трассировки)
    master_supplier_id    text not null,
    supplier_sk           bigint references dm.dim_supplier(supplier_sk),  -- версия поставщика на дату заказа
    item_id               text not null references dm.dim_item(item_id),
    order_dttm_msk        timestamp not null,        -- локальное МСК, как в 1С
    order_date            date not null,
    order_type            text not null,
    delivery_city         text,
    currency              char(3) not null,
    fx_rate_to_rub        numeric(18,6) not null,    -- курс на дату заказа
    uom_code              text not null references dm.dim_uom(uom_code),
    qty                   numeric(18,4) not null check (qty > 0),
    qty_base              numeric(18,4),             -- NULL, если ЕИ строки несовместима с базовой ЕИ позиции
    price                 numeric(18,4) not null,    -- в валюте заказа, за ЕИ строки
    plan_price            numeric(18,4),
    amount_rub            numeric(20,2) not null,    -- qty * price * fx
    plan_amount_rub       numeric(20,2),
    price_per_base_rub    numeric(18,6),             -- NULL при несовместимой ЕИ
    planned_delivery_date date not null,
    status                text not null check (status in ('active','cancelled')),
    updated_at            timestamp not null,
    version_cnt           int not null,              -- сколько версий строки было в выгрузке
    -- флаги качества: строки не выкидываем, а помечаем
    dq_item_unknown       boolean not null,
    dq_uom_incompatible   boolean not null,
    dq_fx_suspect         boolean not null,          -- CNY: цена в 7 раз ниже рыночной после пересчёта
    dq_supplier_scd_gap   boolean not null,          -- на дату заказа у кода нет версии в справочнике
    primary key (order_id, line_no)
);
create index on dm.fct_po_line (master_supplier_id, planned_delivery_date);
create index on dm.fct_po_line (item_id, order_date);
create index on dm.fct_po_line (order_date);

-- ---------------------------------------------------------------------
-- Факт: событие приёмки.
-- Зерно: одна строка = одно уникальное событие приёмки (receipt_id / event_id из Kafka).
-- ---------------------------------------------------------------------
create table dm.fct_receipt (
    receipt_id            text primary key,
    order_id              text not null,
    line_no               int  not null,
    received_at_utc       timestamptz not null,
    received_date_msk     date not null,             -- дата приёмки по МСК — с ней сравниваем плановую дату
    qty_received          numeric(18,4) not null check (qty_received > 0),
    quality_status        text not null check (quality_status in ('accepted','partially_rejected','rejected')),
    warehouse_code        text not null,
    dq_line_cancelled     boolean not null,          -- приёмка по отменённой строке
    dq_before_order       boolean not null,          -- приёмка раньше даты заказа (оформление задним числом)
    foreign key (order_id, line_no) references dm.fct_po_line(order_id, line_no)
);
create index on dm.fct_receipt (order_id, line_no);

-- ---------------------------------------------------------------------
-- Витрина OTIF.
-- Зерно: одна строка = одна активная строка заказа с плановой датой поставки <= as_of_date.
-- ---------------------------------------------------------------------
create table dm.mart_otif_line (
    order_id              text not null,
    line_no               int  not null,
    master_supplier_id    text not null,
    planned_delivery_date date not null,
    qty_ordered           numeric(18,4) not null,
    qty_accepted_on_time  numeric(18,4) not null,    -- принято (accepted) с датой МСК <= плановой
    qty_received_total    numeric(18,4) not null,    -- всё, что пришло, в любом статусе и в любой день
    first_receipt_date    date,
    last_receipt_date     date,
    is_delivered          boolean not null,          -- пришло хоть что-то
    is_on_time            boolean not null,          -- последняя приёмка <= плановой даты
    is_in_full            boolean not null,          -- принято (accepted) >= заказано
    is_otif               boolean not null,          -- принято вовремя и в полном объёме
    as_of_date            date not null,
    primary key (order_id, line_no)
);
create index on dm.mart_otif_line (master_supplier_id, planned_delivery_date);
