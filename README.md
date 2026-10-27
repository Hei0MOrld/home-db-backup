# home-db-backup

自宅の古いPC(常時稼働のUbuntu機)で、クラウドの Postgres(Supabase / Neon)を毎晩**暗号化してバックアップ**し、
**本当に戻せるかを月1回自動で確かめ**、**止まったら気づける**ようにした仕組みです。

きっかけは、同じ機械で動かしていた別の定期処理が **44 日間だれにも気づかれずに失敗していた**こと
(→ [POSTMORTEM.md](POSTMORTEM.md))。その反省を、最初から組み込んで作り直しました。

```
 クラウドDB (Supabase / Neon)
        │ pg_dump(毎晩 3:30, cron)
        ▼
 ┌─ 自宅のバックアップ機(Ubuntu, 常時稼働)────────────┐
 │ server/backup.sh                                       │
 │   pg_dump → age で暗号化(公開鍵だけ置く)→ 30世代保存 │
 │   → status.json(成功の合図。対象0件でも必ず書く)     │
 │ server/restore_test.sh(月1回、鍵は標準入力で渡す)    │
 │   復号 → 使い捨て Postgres に復元 → テーブル数・行数    │
 └────────────────────────────────────────────────────────┘
        │ ssh + tar(毎日 12:40)
        ▼
 ┌─ メインPC(秘密鍵はここだけ)────────────────────────┐
 │ client/backup_pull.py                                  │
 │   取り込み → status が30時間以上古い / 失敗あり /      │
 │   復元テスト失敗 → 終了コード1 → 既存の監視が通知       │
 └────────────────────────────────────────────────────────┘
```

## 決めたこと

| 決めたこと | 理由 |
|---|---|
| **本番のDBは自宅に置かない**(クラウドのまま、自宅はバックアップ係) | 家庭の回線・停電・自分の卒業後を考えると、公開アプリの本番は無料のマネージドDBの方が止まらない。RAM 8GB の古いPCで Supabase 一式を自前で動かすのも重い |
| **秘密鍵をバックアップ機に置かない**(age の公開鍵だけ) | 機械ごと盗まれても中身は読めない。復元テストのときだけ、鍵を標準入力で渡してメモリ上(/dev/shm)に置き、終わったら消す |
| **「失敗の通知」ではなく「成功の合図」を見る** | 失敗を知らせる作りだと、機械ごと止まったとき何も来ない。毎晩 status.json を書かせ、取り込み側が「古い」ことで異常に気づく |
| **戻せるかを実際に戻して確かめる** | バックアップは「取れた」ではなく「戻せた」で初めて意味がある。月1回、使い捨てのコンテナに復元してテーブル数と行数を数える |
| **ポートを開けない** | バックアップ機は外に出ていく通信と、LAN 内の SSH だけ。Docker のポートは 127.0.0.1 に限定 |

## テスト

- `tests/test_backup_pull.py`: 取り込み側の判定(古い・失敗あり・復元テストの時期)
- `tests/e2e.sh`: 本物の Postgres にデータを入れ → `backup.sh` → 暗号化されているか → わざと失敗する対象で終了コード1になるか → `restore_test.sh` で 2 テーブル 2,500 行が戻るか → 鍵なしでは動かないか
- CI(GitHub Actions)で shellcheck・単体テスト・e2e を毎回実行

## 使い方

バックアップ機(Ubuntu、Docker と age が入っていること):

```bash
git clone https://github.com/Hei0MOrld/home-db-backup ~/home-db-backup
mkdir -p ~/backup && chmod 700 ~/backup
# 鍵は秘密鍵を持つ側(メインPC)で作り、公開鍵だけをバックアップ機へ
#   age-keygen -o ~/.backup-keys/backup.agekey   → 出てきた "age1..." を ↓ に
echo "age1..." > ~/backup/recipient.txt
cp ~/home-db-backup/targets.conf.example ~/backup/targets.conf && chmod 600 ~/backup/targets.conf
crontab -e   # crontab.example を参照
```

取り込み側(メインPC、Windows / Mac / Linux):

```bash
BACKUP_HOST=backup@192.168.1.20 BACKUP_DEST=/path/to/hdd/db-backup python client/backup_pull.py
```

毎日1回タスクスケジューラ / cron で動かし、終了コードが 0 でなければ通知されるようにします
(私は既存の監視の仕組みが、失敗が2時間続いたら LINE に送るようにしています)。

`server/wake_main_pc.sh` は同じ機械でメインPCを朝に Wake-on-LAN で起こすスクリプトで、
障害のあと IP が変わっても動くように直したものです(バックアップとは独立)。

---

**English summary:** Nightly `pg_dump` of managed Postgres (Supabase/Neon) on an always-on home Linux box,
encrypted with `age` (only the public key lives on the box), with a pull-based freshness check
("alert when the success signal goes stale", not "alert on failure") and a monthly automated restore test
into a throwaway container. Built after a cron job on the same machine failed silently for 44 days —
see [POSTMORTEM.md](POSTMORTEM.md). CI runs shellcheck, unit tests and a full backup→restore round trip.

License: MIT
