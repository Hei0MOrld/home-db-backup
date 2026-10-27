"""client/backup_pull.py の判定ロジックのテスト(ssh や Docker は使わない)。"""
import datetime
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "client"))
import backup_pull as bp  # noqa: E402

JST = datetime.timezone(datetime.timedelta(hours=9))
NOW = datetime.datetime(2026, 10, 28, 12, 40, tzinfo=JST)


def iso(hours_ago):
    return (NOW - datetime.timedelta(hours=hours_ago)).isoformat()


def test_fresh_and_ok_is_healthy():
    st = {"time": iso(9), "ok": 1, "ng": 0, "targets": {"app": "ok 16K"}}
    assert bp.status_problems(st, NOW) == []


def test_no_targets_is_healthy():
    # 対象0件でも status.json は書かれる。「動いている」合図としては正常
    st = {"time": iso(9), "ok": 0, "ng": 0, "targets": {}}
    assert bp.status_problems(st, NOW) == []


def test_stale_status_is_reported():
    # バックアップ機が止まると status.json が更新されない。これを拾うのがこの仕組みの肝
    st = {"time": iso(49), "ok": 1, "ng": 0, "targets": {"app": "ok 16K"}}
    problems = bp.status_problems(st, NOW)
    assert len(problems) == 1 and "49 時間" in problems[0]


def test_failed_target_is_named():
    st = {"time": iso(9), "ok": 1, "ng": 1, "targets": {"app": "ok 16K", "shop": "failed"}}
    problems = bp.status_problems(st, NOW)
    assert problems == ["バックアップ失敗: shop"]


def test_stale_and_failed_both_reported():
    st = {"time": iso(72), "ok": 0, "ng": 1, "targets": {"app": "failed"}}
    assert len(bp.status_problems(st, NOW)) == 2


def test_restore_due_when_never_run():
    assert bp.restore_due(None, NOW)


def test_restore_not_due_within_30_days():
    assert not bp.restore_due({"time": iso(24 * 29)}, NOW)


def test_restore_due_after_30_days():
    assert bp.restore_due({"time": iso(24 * 30)}, NOW)
