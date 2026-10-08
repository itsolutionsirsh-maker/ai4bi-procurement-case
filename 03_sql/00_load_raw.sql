-- Слой RAW: всё грузим как text, ничего не приводим. Типизация и чистка — в слое STG.
-- Причина: выгрузка «как смог, за вечер», любой кривой формат даты/числа уронит COPY.
drop schema if exists raw cascade;
create schema raw;

create table raw.po_headers (order_id text, supplier_id text, order_dttm_msk text, currency text, delivery_city text, order_type text);
create table raw.po_lines   (order_id text, line_no text, item_id text, qty text, price text, plan_price text, uom_code text, planned_delivery_date text, status text, updated_at text);
create table raw.receipts   (receipt_id text, order_id text, line_no text, received_at_utc text, qty_received text, quality_status text, warehouse_code text);
create table raw.suppliers  (supplier_id text, inn text, supplier_name text, region text, reliability_class text, valid_from text, valid_to text, is_current text);
create table raw.items      (item_id text, item_name text, category text, category_reported text, uom_code text);
create table raw.uom        (uom_code text, uom_name text, base_uom text, factor_to_base text);
create table raw.fx_rates   (rate_date text, currency text, rate_to_rub text);

\copy raw.po_headers from '../data/po_headers.csv' with (format csv, delimiter ';', header true, encoding 'UTF8')
\copy raw.po_lines   from '../data/po_lines.csv'   with (format csv, delimiter ';', header true, encoding 'UTF8')
\copy raw.receipts   from '../data/receipts.csv'   with (format csv, delimiter ';', header true, encoding 'UTF8')
\copy raw.suppliers  from '../data/suppliers.csv'  with (format csv, delimiter ';', header true, encoding 'UTF8')
\copy raw.items      from '../data/items.csv'      with (format csv, delimiter ';', header true, encoding 'UTF8')
\copy raw.uom        from '../data/uom.csv'        with (format csv, delimiter ';', header true, encoding 'UTF8')
\copy raw.fx_rates   from '../data/fx_rates.csv'   with (format csv, delimiter ';', header true, encoding 'UTF8')
