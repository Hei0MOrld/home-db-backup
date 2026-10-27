"""
バックアップ機が毎晩とった暗号化バックアップを手元(別のマシン)に取り込み、異常なら失敗終了する。
タスクスケジューラ / cron で毎日1回動かし、終了コードを監視する(失敗が続いたら通知)。

流れ:
  1. バックアップ機の $BACKUP_DIR/{data,status.json,restore_status.json} を ssh + tar で受け取り
     BACKUP_DEST に展開(中身は age で暗号化済み)
  2. status.json が STALE_HOURS 以上古い / ng>0 / 取れない → 失敗
     バックアップ機が落ちている・cron が止まった・クラウドDBに入れない、を全部ここで拾う。
     「失敗の通知」ではなく「成功の合図が途切れたこと」を見るので、機械ごと止まる故障も拾える
  3. 戻せるかテストが RESTORE_EVERY_DAYS 以上前(または未実施)なら、秘密鍵を標準入力で渡して
     server/restore_test.sh を実行。ng>0 なら失敗

設定は環境変数:
  BACKUP_HOST   ssh 先(例 backup@192.168.1.20)
  BACKUP_DEST   取り込み先(例 /mnt/hdd/db-backup, D:\\db-backup)
  BACKUP_KEY    age の秘密鍵(既定 ~/.backup-keys/backup.agekey)
  REMOTE_DIR    バックアップ機のデータの場所(既定 ~/backup)
  REMOTE_REPO   バックアップ機のこのリポジトリの場所(既定 ~/home-db-backup)
"""
import datetime
import io
import json
import os
import subprocess
import sys
import tarfile

# Windows のタスクから pythonw(画面なし)で起動されると stdout/stderr が None で落ちる
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w", encoding="utf-8")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w", encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8")

HOST = os.environ.get("BACKUP_HOST", "")
DEST = os.environ.get("BACKUP_DEST", os.path.join(os.path.expanduser("~"), "db-backup"))
KEY = os.environ.get("BACKUP_KEY", os.path.join(os.path.expanduser("~"), ".backup-keys", "backup.agekey"))
REMOTE_DIR = os.environ.get("REMOTE_DIR", "~/backup")
REMOTE_REPO = os.environ.get("REMOTE_REPO", "~/home-db-backup")
STALE_HOURS = 30
RESTORE_EVERY_DAYS = 30


def log(msg):
    line = f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line)
    try:
        with open(os.path.join(DEST, "pull.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def ssh(cmd, **kw):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST, cmd],
                          capture_output=True, **kw)


def age_hours(iso, now=None):
    t = datetime.datetime.fromisoformat(iso)
    now = now or datetime.datetime.now(t.tzinfo)
    return (now - t).total_seconds() / 3600


def pull():
    r = ssh(f"tar -C {REMOTE_DIR} -cf - data status.json "
            f"$(test -f {REMOTE_DIR}/restore_status.json && echo restore_status.json)", timeout=600)
    if r.returncode != 0:
        raise RuntimeError(f"バックアップ機から取れない: {r.stderr.decode(errors='replace')[:200]}")
    with tarfile.open(fileobj=io.BytesIO(r.stdout)) as tf:
        tf.extractall(DEST, filter="data")
    n = sum(len(fs) for _, _, fs in os.walk(os.path.join(DEST, "data")))
    log(f"取り込み OK({len(r.stdout) // 1024}KB, ファイル {n} 個)")


def status_problems(st, now=None):
    """status.json の中身から問題のリストを返す(空なら正常)。"""
    problems = []
    age = age_hours(st["time"], now)
    if age > STALE_HOURS:
        problems.append(f"バックアップが {age:.0f} 時間更新されていない")
    if st.get("ng"):
        failed = [k for k, v in st.get("targets", {}).items() if str(v).startswith("failed")]
        problems.append(f"バックアップ失敗: {', '.join(failed)}")
    return problems


def restore_due(rs, now=None):
    return rs is None or age_hours(rs["time"], now) >= RESTORE_EVERY_DAYS * 24


def check_status():
    st = json.load(open(os.path.join(DEST, "status.json"), encoding="utf-8"))
    log(f"status: ok={st.get('ok')} ng={st.get('ng')} {age_hours(st['time']):.1f}時間前")
    return status_problems(st)


def maybe_restore_test():
    path = os.path.join(DEST, "restore_status.json")
    rs = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else None
    if not restore_due(rs):
        return []
    log("戻せるかテストを実行")
    with open(KEY, "rb") as k:
        r = ssh(f"BACKUP_DIR={REMOTE_DIR} bash {REMOTE_REPO}/server/restore_test.sh", stdin=k, timeout=1800)
    out = r.stdout.decode(errors="replace").strip()
    for line in out.splitlines():
        log(line)
    pull()  # restore_status.json を取り直す
    return [] if r.returncode == 0 else [f"戻せるかテスト失敗: {out[-200:]}"]


def main():
    if not HOST:
        print("BACKUP_HOST を設定してください", file=sys.stderr)
        return 2
    os.makedirs(DEST, exist_ok=True)
    try:
        pull()
        problems = check_status() + maybe_restore_test()
    except Exception as e:
        problems = [f"{type(e).__name__}: {e}"]
    for p in problems:
        log(f"⚠ {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
