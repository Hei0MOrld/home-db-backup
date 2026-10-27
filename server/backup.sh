#!/bin/bash
# クラウドの Postgres(Supabase / Neon など)を毎晩バックアップする。自宅の常時稼働機で cron から動かす。
#
# 流れ:
#   targets.conf の各行「名前|接続URL|pg_dump の追加引数(任意)」ごとに
#   pg_dump(postgres:17 コンテナ)→ age で暗号化 → $BACKUP_DIR/data/<名前>/<名前>_<日時>.dump.age
#   古いものは KEEP 個だけ残す。結果は $BACKUP_DIR/status.json に必ず書く(対象0件でも)。
#   別のマシンの client/backup_pull.py が毎日これを取り込み、status を見て異常なら失敗終了する。
#
# 復号用の秘密鍵はこの機械に置かない。ここにあるのは公開鍵 recipient.txt だけなので、
# 機械ごと盗まれてもバックアップの中身は読めない。
#
# 終了コード: 全部成功(または対象0件)=0 / 1件でも失敗=1

set -uo pipefail
umask 077

B="${BACKUP_DIR:-$HOME/backup}"
KEEP="${KEEP:-30}"
IMAGE="postgres:17-alpine"
RECIPIENT="$(cat "$B/recipient.txt")"
TS="$(date +%Y%m%d-%H%M%S)"
ok=0; ng=0; details=()

log() { echo "[backup] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

touch "$B/targets.conf"
while IFS='|' read -r name url extra; do
    [[ -z "${name// }" || "$name" == \#* ]] && continue
    dir="$B/data/$name"
    mkdir -p "$dir"
    out="$dir/${name}_${TS}.dump.age"
    # 空のダンプや途中で切れたダンプを成功扱いしないよう、1KB 未満は失敗にする
    # shellcheck disable=SC2086
    if docker run --rm --network host "$IMAGE" \
            pg_dump -Fc --no-owner --no-privileges $extra "$url" \
        | age -r "$RECIPIENT" > "$out.part" \
        && [ "$(stat -c %s "$out.part")" -gt 1024 ]; then
        mv "$out.part" "$out"
        size=$(du -h "$out" | cut -f1)
        log "$name: OK ($size)"
        details+=("\"$name\": \"ok $size\"")
        ok=$((ok + 1))
        # ファイル名はこのスクリプトが <名前>_<日時>.dump.age で付けるので ls で十分
        # shellcheck disable=SC2012
        ls -1t "$dir"/*.dump.age 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
    else
        rm -f "$out.part"
        log "$name: 失敗"
        details+=("\"$name\": \"failed\"")
        ng=$((ng + 1))
    fi
done < "$B/targets.conf"

detail_json="$(IFS=,; echo "${details[*]:-}")"
cat > "$B/status.json" <<EOF
{"time": "$(date -Iseconds)", "ok": $ok, "ng": $ng, "targets": {${detail_json}}}
EOF
log "完了 ok=$ok ng=$ng"
[ "$ng" -eq 0 ]
