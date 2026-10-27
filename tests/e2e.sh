#!/bin/bash
# 端から端までの確認: 本物の Postgres にデータを入れる → backup.sh で暗号化バックアップ →
# restore_test.sh で別のコンテナに戻す → 行数が一致するか。Docker と age が必要。
#
#   bash tests/e2e.sh
#
# CI(.github/workflows/ci.yml)でも毎回これを動かしている。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
SRC="bk_e2e_src"
PORT=55499
export BACKUP_DIR="$WORK/backup"

cleanup() { docker rm -f "$SRC" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$BACKUP_DIR"
age-keygen -o "$WORK/key.txt" 2>/dev/null
age-keygen -y "$WORK/key.txt" > "$BACKUP_DIR/recipient.txt"

echo "== 元の DB を作る"
docker run -d --name "$SRC" -e POSTGRES_HOST_AUTH_METHOD=trust -p "127.0.0.1:$PORT:5432" \
    postgres:17-alpine >/dev/null
# TCP で確かめる(理由は server/restore_test.sh の同じ箇所)
for _ in $(seq 1 30); do docker exec "$SRC" pg_isready -h 127.0.0.1 -U postgres -q && break; sleep 1; done
docker exec "$SRC" psql -U postgres -q -c "
  create table works (id serial primary key, title text not null);
  create table sales (id serial primary key, work_id int references works(id), qty int);
  insert into works (title) select 'work ' || g from generate_series(1, 500) g;
  insert into sales (work_id, qty) select (g % 500) + 1, g % 7 from generate_series(1, 2000) g;
  analyze;"

echo "selftest|postgresql://postgres@127.0.0.1:$PORT/postgres" > "$BACKUP_DIR/targets.conf"

echo "== backup.sh"
bash "$ROOT/server/backup.sh"
grep -q '"ok": 1, "ng": 0' "$BACKUP_DIR/status.json"
f="$(ls "$BACKUP_DIR"/data/selftest/*.dump.age)"
# 暗号化されていること(平文の Postgres カスタム形式の先頭 "PGDMP" が見えない)
if head -c 5 "$f" | grep -q PGDMP; then echo "暗号化されていない"; exit 1; fi

echo "== 失敗する対象を混ぜると ng になり、終了コード 1"
echo "broken|postgresql://postgres@127.0.0.1:1/postgres" >> "$BACKUP_DIR/targets.conf"
if bash "$ROOT/server/backup.sh"; then echo "失敗が成功扱いになった"; exit 1; fi
grep -q '"broken": "failed"' "$BACKUP_DIR/status.json"
rm -rf "$BACKUP_DIR/data/broken"

echo "== restore_test.sh(鍵は標準入力から)"
bash "$ROOT/server/restore_test.sh" < "$WORK/key.txt"
python3 - "$BACKUP_DIR/restore_status.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
t = r["targets"]["selftest"]
assert r["ng"] == 0 and t["ok"], r
assert t["tables"] == 2 and t["rows"] == 2500, t
print(f"復元 OK: テーブル {t['tables']} / 行 {t['rows']}")
EOF

echo "== 鍵なしでは restore_test.sh が動かない"
if echo "not a key" | bash "$ROOT/server/restore_test.sh"; then echo "鍵なしで通った"; exit 1; fi

echo "e2e: すべて OK"
