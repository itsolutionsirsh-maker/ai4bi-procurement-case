#!/usr/bin/env bash
# Полный прогон: загрузка CSV → модель → запросы → результаты в results/.
# Требования: PostgreSQL 14+, psql; CSV из dataset.zip распакованы в ../data/
set -euo pipefail
DB=${DB:-raft}
cd "$(dirname "$0")"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 00_load_raw.sql
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 01_ddl.sql
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f 02_transform.sql
for q in q1_otif q2_price_anomalies q3_concentration dq_checks recon_turnover otif_ladder; do
  [ -f "$q.sql" ] || continue
  psql -v ON_ERROR_STOP=1 -q -d "$DB" --csv -f "$q.sql" > "results/$q.csv"
  echo "ok: $q -> results/$q.csv ($(($(wc -l < results/$q.csv)-1)) строк)"
done
