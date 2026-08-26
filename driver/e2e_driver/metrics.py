"""計測記録（metrics）— 通しの実行で測った値を、後から比較できる形で残す（issue #49）。

**journey（画面と遷移の記録）とは別の層**。journey は「どの画面を通ったか」で、
こちらは「そのとき何を測ったか」。導入先が独自に作り込んだ形を一般化したもので、
**先頭行にその回の目的と設定を書く**のが要点。これが無いと
「**この記録は比較してよい記録か**」が後から判断できない
（例: デバッグ機能で状態を注入した回はバランスの参考にならない）。

出力は 2 つ:
  <dir>/<runId>.jsonl … 1 行 1 イベント。**先頭行が run のヘッダ**（kind="run"）
  <dir>/summary.csv   … 実行単位の 1 行。複数回を並べて比較するため

**数値の意味づけはしない。** 記録するだけで、合否は呼び出し側が決める。
"""
from __future__ import annotations

import csv
import json
import locale
import os
import platform
import secrets
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


class MetricsRecorder:
    """1 回の実行ぶんの記録。`enabled=False` なら**何も書かない**（既定）。"""

    def __init__(self, out_dir: str | os.PathLike[str] | None, *, run_id: str | None = None,
                 enabled: bool = True) -> None:
        self.enabled = bool(enabled and out_dir)
        # **秒解像度だけでは並行実行で衝突する**（mac の実測: 同一秒の 2 本が同じ runId になり、
        # 1 本の jsonl に両方のイベントが混ざり、summary.csv に同じ runId が 2 行できた）。
        # このリポジトリは -DeviceSerial / -HostPort での並行実行を明示サポートしているので、
        # **比較のための記録が比較に使えなくなる**＝目的そのものを損なう。
        # pid（同一ホストの別プロセスを分ける）＋ 短い乱数（同一プロセス内の複数レコーダー）を混ぜる
        self.run_id = run_id or "{0}-{1}-{2}".format(
            datetime.now().strftime("%Y%m%d-%H%M%S"), os.getpid(), secrets.token_hex(2))
        self._dir = Path(out_dir) if out_dir else None
        self._path = self._dir / f"{self.run_id}.jsonl" if self._dir else None
        self._summary: dict[str, Any] = {}
        self._header_written = False

    # ------------------------------------------------------------------ 記録
    def begin(self, purpose: str, **config: Any) -> None:
        """**その回の目的と設定**を先頭行に書く。

        **これを書かない記録は、後から比較してよいか判断できない。**
        `purpose` は「何を測りに行ったか」を人が読む文で、`config` は
        比較に効く条件（対象の版・モード・デバッグ機能を使ったか等）。
        """
        self._write({"kind": "run", "runId": self.run_id, "purpose": purpose,
                     "startedAt": _now(), "host": platform.node(), "config": config})
        self._header_written = True

    def record(self, name: str, value: Any, **extra: Any) -> None:
        """測った値を 1 件記録する。**呼び出し側が name を決める**（キットは意味づけしない）。"""
        self._ensure_header()
        self._write({"kind": "metric", "at": _now(), "name": name, "value": value, **extra})
        self._summary[name] = value

    def note(self, message: str, **extra: Any) -> None:
        """数値ではない観測（例: 途中で出たダイアログ）を残す。"""
        self._ensure_header()
        self._write({"kind": "note", "at": _now(), "message": message, **extra})

    def _ensure_header(self) -> None:
        """**ヘッダの無い記録を作らない**。無ければ入れて、**その場で 1 行警告する**。

        自動で入れるのは「**ヘッダが無い記録は後から解釈できない**」ため。
        ただし**黙って入れると、書いた本人は永遠に気づかない**ので警告を出す
        （見に行った人にしか届かない案内は届かない、という型 ― uapp-dash の #20 と同じ）。
        """
        if self._header_written:
            return
        self.begin("（目的が宣言されていません）")
        if self.enabled:
            print("[uapp_e2e] metrics: begin() が呼ばれていないので、目的が空のヘッダを入れました。"
                  "比較してよい記録かを後から判断できるよう、"
                  "最初に metrics.begin(\"<目的>\", <設定>) を呼んでください", file=sys.stderr)

    # ------------------------------------------------------------------ 保存
    def save(self) -> None:
        """`summary.csv` へ 1 行足す。**列は回ごとに増えうる**ので、既存を読んで結合する。"""
        if not self.enabled or not self._dir or not self._summary:
            return
        path = self._dir / "summary.csv"
        rows: list[dict[str, Any]] = []
        if path.exists():
            rows = self._read_existing(path)
        rows.append({"runId": self.run_id, **{k: str(v) for k, v in self._summary.items()}})
        fields: list[str] = []
        for row in rows:
            for key in row:
                if key not in fields:
                    fields.append(key)
        # **書き途中で全部消えるのを防ぐ**（一時ファイル → 置換）。
        # journey も上書きだが、**失うものが非対称** ― journey.json はその回の走行から
        # 再生成できるのに対し、**summary.csv は複数回の蓄積で、壊れたら過去は戻らない**（mac の指摘）。
        # 並行実行での lost update は別問題（uapp-dash #11 と同クラス）で、ここでは解いていない
        tmp = path.with_suffix(".csv.tmp")
        # **BOM 付き UTF-8 で書く**（`utf-8-sig`）。このファイルは**人が Excel で開く前提**で、
        # **BOM の無い UTF-8 の CSV を Excel は cp932 として読む**ため、無いと列名が化ける。
        # この repo の他の書き分けとは**逆**になる: md は BOM あり / .ps1 は BOM なし /
        # **CSV は「Excel が読む物」として 3 つ目の分類**（BOM あり）。
        # 配布物に BOM を付けて失敗した過去があるが、**あれは manifest ハッシュを持つ
        # スクリプトの話**で、ここは対象が違う（読み手が Excel）。
        with tmp.open("w", encoding="utf-8-sig", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields, restval="")
            writer.writeheader()
            writer.writerows(rows)
        os.replace(tmp, path)


    def _read_existing(self, path: Path) -> list[dict[str, Any]]:
        """既存の `summary.csv` を読む。**壊れていても例外を投げない**。

        `summary.csv` は**人が比較のために開くファイル**なので、
        **Excel で保存されて cp932 になる**（mac が実測で `UnicodeDecodeError` を再現）。
        そこで **utf-8（BOM 有無どちらも）→ cp932 → ロケール既定 → 置換**の順に試す。
        **いきなり置換にしない**のは、置換で読むと**人が書いた非 ASCII を壊したまま書き戻す**ため。

        **1 段目は `utf-8` ではなく `utf-8-sig`**。こちらが書くファイルには BOM が付くので、
        素の `utf-8` で読むと**成功したうえで最初の列名が `﻿runId` になる**
        （例外が出ないぶん質が悪い ― 列が 1 つ増えたように見える）。
        `utf-8-sig` は BOM が無ければ素の utf-8 として読むので、**両方を 1 段で賄える**。

        **`OSError` だけを捕まえるのでは足りない**（巨大フィールドで `_csv.Error` も出る）。
        ここは **session フィクスチャの teardown** から呼ばれるので、
        **投げるとテストが全部緑でもセッションが落ちる**（計測の副産物がテスト結果を殺す）。
        """
        # **候補は「ファイルの出自」で決める。「読む側のロケール」では決めない。**
        # `summary.csv` は**人が開いて回覧するファイル**で、
        # **Windows の同僚が Excel で保存したものを mac で読む**のはこのプロジェクトそのものの状況。
        # ロケール既定だけに頼ると、**mac（`getpreferredencoding` が UTF-8）では 2 段目が
        # 1 段目と同じになり、cp932 の中身が置換段へ落ちて列名まで化ける**
        # （mac の実測。同じファイルが Windows では読めて mac では壊れる＝原因の置き場所が違う）
        encodings = ["utf-8-sig", "cp932"]
        preferred = locale.getpreferredencoding(False)
        if preferred and preferred.lower().replace("-", "") not in [
                e.lower().replace("-", "") for e in encodings]:
            encodings.append(preferred)
        for i, enc in enumerate(encodings):
            try:
                with path.open(encoding=enc, newline="") as f:
                    rows = list(csv.DictReader(f))
                if i > 0:
                    print(f"[uapp_e2e] metrics: summary.csv が utf-8 ではありませんでした"
                          f"（{enc} として読めた）。書き直しは BOM 付き utf-8 になります: {path}",
                          file=sys.stderr)
                return rows
            except UnicodeDecodeError:
                continue
            except Exception as exc:
                print(f"[uapp_e2e] metrics: 既存の summary.csv を読めませんでした（{exc}）。"
                      f"今回のぶんだけを書き直します: {path}", file=sys.stderr)
                return []
        try:
            with path.open(encoding="utf-8-sig", errors="replace", newline="") as f:
                rows = list(csv.DictReader(f))
            print(f"[uapp_e2e] metrics: summary.csv の文字コードを判別できず、"
                  f"読めない箇所を置き換えて読みました（元の文字が失われます）: {path}",
                  file=sys.stderr)
            return rows
        except Exception as exc:
            print(f"[uapp_e2e] metrics: 既存の summary.csv を読めませんでした（{exc}）。"
                  f"今回のぶんだけを書き直します: {path}", file=sys.stderr)
            return []
    # ---------------------------------------------------------------- 内部
    def _write(self, obj: dict[str, Any]) -> None:
        if not self.enabled or not self._path:
            return
        self._path.parent.mkdir(parents=True, exist_ok=True)
        with self._path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
