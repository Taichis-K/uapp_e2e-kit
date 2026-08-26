"""metrics の単体テスト（issue #49）。**デバイス不要**で毎回走る。

新しい配布ファイルには網が要る（`journey` には `test_journey_unit.py` がある）。
**ここに書いてあるのは、すべて mac のレビューが実測で見つけた壊れ方**。
"""
import csv
import json
from pathlib import Path

from e2e_driver.metrics import MetricsRecorder


def _events(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def test_disabled_recorder_writes_nothing(tmp_path):
    """既定（出力先なし）では 1 バイトも書かない。"""
    rec = MetricsRecorder(None, enabled=False)
    rec.begin("何か"); rec.record("x", 1); rec.note("y"); rec.save()
    assert list(tmp_path.iterdir()) == []


def test_header_comes_first_even_when_only_note_is_called(tmp_path, capsys):
    """`note()` だけでも**先頭行はヘッダ**になり、**その場で警告が出る**。

    `record()` にだけ自動ヘッダがあり `note()` に無いと、
    「ヘッダの無い記録を作らない」という不変条件がそこで破れる（mac の指摘）。
    """
    rec = MetricsRecorder(tmp_path, run_id="t")
    rec.note("ダイアログが出た")
    events = _events(tmp_path / "t.jsonl")
    assert events[0]["kind"] == "run", "先頭はヘッダでなければならない"
    assert "begin() が呼ばれていない" in capsys.readouterr().err, "黙って補完してはいけない"


def test_run_id_differs_between_recorders(tmp_path):
    """**並行実行で衝突しない**。秒解像度だけだと同一秒の 2 本が同じ runId になり、
    1 本の jsonl に両方が混ざって**比較のための記録が比較に使えなくなる**（mac が実測）。
    """
    a = MetricsRecorder(tmp_path)
    b = MetricsRecorder(tmp_path)
    assert a.run_id != b.run_id


def test_summary_reads_cp932_without_losing_characters(tmp_path, capsys):
    """**cp932 で保存された `summary.csv`** でも例外を投げず、**人の非 ASCII を壊さない**。

    `summary.csv` は**人が比較のために開くファイル**で、Excel で保存すると cp932 になる
    （mac が `UnicodeDecodeError` を実測）。ここは session フィクスチャの teardown から
    呼ばれるので、**投げるとテストが全部緑でもセッションが落ちる**。
    """
    (tmp_path / "summary.csv").write_bytes("runId,名前\nold,値\n".encode("cp932"))
    rec = MetricsRecorder(tmp_path, run_id="t2")
    rec.begin("目的"); rec.record("seconds", 1.5)
    rec.save()   # 例外を投げないこと自体が検証

    with (tmp_path / "summary.csv").open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    assert any(r["runId"] == "t2" for r in rows), "今回のぶんが書かれていない"
    # **いきなり置換で読むと「値」が化けたまま書き戻される**ので、そこまで見る
    old_row = next(r for r in rows if r["runId"] == "old")
    assert old_row["名前"] == "値", "既存の非 ASCII が壊れている"
    assert "utf-8 ではありませんでした" in capsys.readouterr().err, "黙って読み替えてはいけない"


def test_summary_survives_broken_csv(tmp_path, capsys):
    """**巨大なフィールド**（`_csv.Error`）でも例外を投げず、今回のぶんは残す。

    `OSError` だけを捕まえるのでは足りない、という mac の実測から。
    """
    (tmp_path / "summary.csv").write_text('runId,x\n"' + "a" * 200_000 + "\n", encoding="utf-8")
    rec = MetricsRecorder(tmp_path, run_id="t3")
    rec.begin("目的"); rec.record("seconds", 2.5)
    rec.save()

    with (tmp_path / "summary.csv").open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    assert [r["runId"] for r in rows] == ["t3"], "今回のぶんだけが残るはず"
    assert "読めませんでした" in capsys.readouterr().err, "黙って捨ててはいけない"


def test_summary_accumulates_and_columns_can_grow(tmp_path):
    """回をまたいで蓄積し、**列が増えても既存の行を壊さない**。"""
    a = MetricsRecorder(tmp_path, run_id="r1"); a.begin("1 回目"); a.record("x", 1); a.save()
    b = MetricsRecorder(tmp_path, run_id="r2"); b.begin("2 回目"); b.record("y", 2); b.save()
    with (tmp_path / "summary.csv").open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    assert [r["runId"] for r in rows] == ["r1", "r2"]
    assert rows[0]["x"] == "1" and rows[1]["y"] == "2"
    assert rows[0]["y"] == "" and rows[1]["x"] == ""   # 無い列は空で埋まる


def test_save_leaves_no_temporary_file(tmp_path):
    """一時ファイル経由で置換するが、**残骸を残さない**。"""
    rec = MetricsRecorder(tmp_path, run_id="r3"); rec.begin("目的"); rec.record("x", 1); rec.save()
    assert not list(tmp_path.glob("*.tmp")), "一時ファイルが残っている"


def test_cp932_is_recovered_even_where_locale_default_is_utf8(tmp_path, capsys, monkeypatch):
    """**読む側のロケールが UTF-8 でも** cp932 の既存行を壊さない（issue #49・mac の実測）。

    候補を「utf-8 → **ロケール既定**」にしていたため、**mac（`getpreferredencoding` が UTF-8）では
    2 段目が 1 段目と同じ**になり、cp932 の中身が置換段へ落ちて**列名まで化けた**
    （同じファイルが Windows では読めて mac では壊れる）。
    **壊れ方はファイルの出自の性質**（Windows の Excel で保存された）で、
    **読む側のロケールの性質ではない** ― だから候補に cp932 を明示で置く。

    この条件は **mac でしか自然には出ない**ので、ロケール既定を差し替えて Windows でも検出する。
    """
    import locale as _locale
    monkeypatch.setattr(_locale, "getpreferredencoding", lambda do_setlocale=True: "UTF-8")

    (tmp_path / "summary.csv").write_bytes("runId,名前\nold,値\n".encode("cp932"))
    rec = MetricsRecorder(tmp_path, run_id="t4")
    rec.begin("目的"); rec.record("x", 1); rec.save()

    with (tmp_path / "summary.csv").open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    old_row = next(r for r in rows if r["runId"] == "old")
    assert old_row["名前"] == "値", "ロケール既定が UTF-8 の環境で既存の非 ASCII が壊れている"
    assert "cp932 として読めた" in capsys.readouterr().err


def test_summary_is_written_with_bom_so_excel_can_open_it(tmp_path):
    """**BOM 付き UTF-8 で書く**（ユーザー判断 2026-08-26）。

    `summary.csv` は**人が Excel で開く前提**のファイルで、
    **BOM の無い UTF-8 の CSV を Excel は cp932 として読む**ため、無いと列名が化ける。
    md は BOM あり / `.ps1` は BOM なし、と既に使い分けているところへ、
    **CSV は「Excel が読む物」として 3 つ目の分類**が加わる。
    """
    rec = MetricsRecorder(tmp_path, run_id="t5")
    rec.begin("目的"); rec.record("名前", "値"); rec.save()

    head = (tmp_path / "summary.csv").read_bytes()[:3]
    assert head == b"\xef\xbb\xbf", f"BOM が無い（先頭 3 バイト = {head!r}）"


def test_our_own_file_round_trips_without_a_bom_in_the_column_name(tmp_path):
    """**自分が書いたファイルを自分で読み直しても列名が壊れない**。

    読み側の 1 段目が素の `utf-8` だと、BOM 付きファイルを**例外なしで読んでしまい**、
    最初の列名が `﻿runId` になる（列が 1 つ増えたように見えるだけで、失敗しない）。
    **2 回目の `save()` で既存行の runId が引けなくなる**ので、蓄積が壊れる。
    """
    rec1 = MetricsRecorder(tmp_path, run_id="first")
    rec1.begin("1 回目"); rec1.record("秒", 1.5); rec1.save()

    rec2 = MetricsRecorder(tmp_path, run_id="second")
    rec2.begin("2 回目"); rec2.record("秒", 2.5); rec2.save()

    with (tmp_path / "summary.csv").open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    assert [r["runId"] for r in rows] == ["first", "second"], "蓄積が壊れている"
    assert all(not k.startswith("﻿") for r in rows for k in r), "列名に BOM が残っている"
