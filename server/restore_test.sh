#!/bin/bash
# バックアップが本当に戻せるかの確認。
#
# 秘密鍵はこの機械に置かないので、鍵を持っている側から標準入力で渡して実行する:
#   ssh backup-host 'bash ~/home-db-backup/server/restore_test.sh' < ~/.backup-keys/backup.agekey
# 鍵は /dev/shm(メモリ上)に一時保存し、終了時に消す。
#
# 各対象の最新ファイルを復号 → 使い捨ての postgres:17 コンテナに pg_restore →
# ユーザーテーブル数と総行数を数える。テーブルが1つ以上戻れば OK。
# Supabase 固有のロールや拡張が無いことによる pg_restore の警告は無視する。
# 結果は $BACKUP_DIR/restore_status.json。終了コード: 全部OK(または対象0件)=0 / それ以外=1

set -uo pipefail

B="${BACKUP_DIR:-$HOME/backup}"
IMAGE="postgres:17-alpine"
C="bk_restore_test"
K="/dev/shm/bk_restore.key"

umask 077
cat > "$K"
cleanup() { shred -u "$K" 2>/dev/null; docker rm -f "$C" >/dev/null 2>&1; }
trap cleanup EXIT

if ! grep -q "AGE-SECRET-KEY" "$K"; then
    echo "[restore_test] 秘密鍵が標準入力から来ていない"
    exit 1
fi

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null
for _ in $(seq 1 30); do
    docker exec "$C" pg_isready -U postgres -q && break
    sleep 1
done

ok=0; ng=0; details=()
for dir in "$B"/data/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    # ファイル名は backup.sh が <名前>_<日時>.dump.age で付けるので ls で十分
    # shellcheck disable=SC2012
    latest="$(ls -1t "$dir"*.dump.age 2>/dev/null | head -1)"
    [ -n "$latest" ] || continue
    db="rt_${name//[^a-zA-Z0-9]/_}"
    docker exec "$C" createdb -U postgres "$db"
    age -d -i "$K" "$latest" | docker exec -i "$C" pg_restore -U postgres -d "$db" \
        --no-owner --no-privileges >/dev/null 2>&1
    counts="$(docker exec "$C" psql -U postgres -d "$db" -tAc \
        "select count(*), coalesce(sum(n_live_tup),0) from pg_stat_user_tables" 2>/dev/null)"
    tables="${counts%%|*}"; rows="${counts##*|}"
    if [ "${tables:-0}" -gt 0 ]; then
        echo "[restore_test] $name: OK テーブル $tables / 行 約$rows ($(basename "$latest"))"
        details+=("\"$name\": {\"ok\": true, \"tables\": $tables, \"rows\": $rows, \"file\": \"$(basename "$latest")\"}")
        ok=$((ok + 1))
    else
        echo "[restore_test] $name: 失敗(テーブルが戻らない)"
        details+=("\"$name\": {\"ok\": false, \"file\": \"$(basename "$latest")\"}")
        ng=$((ng + 1))
    fi
done

detail_json="$(IFS=,; echo "${details[*]:-}")"
cat > "$B/restore_status.json" <<EOF
{"time": "$(date -Iseconds)", "ok": $ok, "ng": $ng, "targets": {${detail_json}}}
EOF
echo "[restore_test] 完了 ok=$ok ng=$ng"
[ "$ng" -eq 0 ]
