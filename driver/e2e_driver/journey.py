"""画面把握・テスト結果・カバレッジの記録（ジャーニー）と自己完結HTMLレポート生成。

各画面の節目で capture() すると dump＋スクリーンショット＋ボタン抽出を journey.json に
追記マージし、capture 間のタップから画面遷移を自動記録する。テストの pass/fail は
pytest 連携（pytest_journey.py の journey フィクスチャ）が記録する。
スキーマ・カバレッジ定義・使い方は docs/07-viewer.md。

レポート生成: python -m e2e_driver.journey <journey_dir> [-o report.html]
探索モード:   python -m e2e_driver.journey serve <journey_dir>
              → ビューアーを http 配信し、ボタンの「▶ タップ」で実機タップ＋遷移先の自動記録
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import time
import webbrowser
from datetime import datetime
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from typing import Any

from . import adb
from .client import BridgeClient, resolve_port
from .gestures import Gestures

FORMAT = "uapp-e2e-journey/1"

# viewer.html 内のデータ差し込み位置（export_html が丸ごと置換する）
_DATA_SLOT = '<script id="journey-data" type="application/json">null</script>'

# dump ノードからボタン情報として転記するキー
_BUTTON_KEYS = ("path", "name", "text", "ui", "rect", "center",
                "interactable", "hittable", "blockedBy")


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _safe_name(screen_id: str) -> str:
    return re.sub(r"[^0-9A-Za-z_-]", "_", screen_id) or "screen"


def _extract_buttons(nodes: list[dict]) -> list[dict]:
    """dump ツリーからボタン（probe が hittable 判定を付けたアクティブノード）を平坦化して抽出。"""
    found: list[dict] = []

    def walk(node: dict) -> None:
        if "hittable" in node and node.get("active"):
            found.append({k: node[k] for k in _BUTTON_KEYS if k in node})
        for child in node.get("children", []):
            walk(child)

    for node in nodes:
        walk(node)
    return found


class JourneyRecorder:
    """journey.json への追記マージ記録。enabled=False なら全メソッドが no-op。

    同じ out_dir への複数回の実行は蓄積される: 画面は id で、テストは名前で上書き。
    """

    def __init__(self, client: BridgeClient | None, out_dir: str | Path | None,
                 enabled: bool = True):
        self.enabled = bool(enabled and client is not None and out_dir is not None)
        self.client = client
        self.out_dir = Path(out_dir) if out_dir else None
        self.current_test: str | None = None
        self._app: dict | None = None
        self._screens: dict[str, dict] = {}
        self._transitions: list[dict] = []
        self._tests: dict[str, dict] = {}
        self._pending_actions: dict[str, list[dict]] = {}
        self._current_screen: str | None = None
        self._current_screen_test: str | None = None
        self._pending_via: str | None = None
        if self.enabled:
            self._load()

    # ------------------------------------------------------------- recording

    def capture(self, screen_id: str, label: str | None = None, *,
                scope: str = "ui", probe: str = "selectable") -> dict | None:
        """現在の画面を記録する（dump＋スクリーンショット＋ボタン抽出）。

        直前の capture から見て画面 id が変わっていれば、その間のタップを via として
        遷移も記録する。同じ id での再 capture は画面情報を上書きする。
        """
        if not self.enabled:
            return None
        if self._app is None:
            self._app = self._collect_app_info()
        dump = self.client.dump(scope=scope, probe=probe)
        screen = {
            "id": screen_id,
            "label": label or self._screens.get(screen_id, {}).get("label") or screen_id,
            "scene": dump.get("scene"),
            "screen": dump.get("screen"),
            "screenshot": self._screencap(screen_id),
            "capturedAt": _now(),
            "buttons": _extract_buttons(dump.get("nodes", [])),
        }
        self._screens[screen_id] = screen
        if self._current_screen and screen_id != self._current_screen:
            # タップ起点の遷移は常に記録。タップなしの自動遷移はテストをまたぐと
            # 「前テストの終了画面→次テストの開始画面」という偽遷移になるため同一テスト内のみ
            if self._pending_via is not None or self._current_screen_test == self.current_test:
                self._add_transition(self._current_screen, screen_id, self._pending_via)
        self._current_screen = screen_id
        self._current_screen_test = self.current_test
        self._pending_via = None
        self.save()
        return screen

    def wrap(self, gestures: Gestures) -> "Gestures | RecordingGestures":
        """タップ操作を記録するプロキシを返す。無効時は素通し。"""
        return RecordingGestures(self, gestures) if self.enabled else gestures

    def record_test(self, name: str, outcome: str, duration: float) -> None:
        """テスト結果を記録する（pytest 連携から呼ばれる）。

        結果は history に累積し、前回 passed → 今回 failed/error なら regressed を立てる
        （AI はこれを「自分の変更が壊した可能性」の調査トリガーにする）。
        操作ログ（actions）も累積マージ: 実行経路が変わっても過去に検証済みのカバレッジを失わない。
        """
        if not self.enabled:
            return
        prev = self._tests.get(name)
        history = list((prev or {}).get("history") or [])
        if prev and not history:  # 旧形式（history無し）からの移行
            history = [{"outcome": prev["outcome"], "ranAt": prev.get("ranAt"),
                        "duration": prev.get("duration")}]
        prev_outcome = history[-1]["outcome"] if history else None
        history.append({"outcome": outcome, "ranAt": _now(), "duration": round(duration, 2)})
        old_actions = (prev or {}).get("actions", [])
        new_actions = self._pending_actions.pop(name, [])
        self._tests[name] = {
            "name": name,
            "outcome": outcome,
            "duration": round(duration, 2),
            "ranAt": _now(),
            "regressed": prev_outcome == "passed" and outcome in ("failed", "error"),
            "history": history[-20:],
            "actions": old_actions + [a for a in new_actions if a not in old_actions],
        }
        self.save()

    def save(self) -> Path | None:
        if not self.enabled:
            return None
        self.out_dir.mkdir(parents=True, exist_ok=True)
        path = self.out_dir / "journey.json"
        data = {
            "format": FORMAT,
            "app": self._app,
            "updatedAt": _now(),
            "screens": list(self._screens.values()),
            "transitions": self._transitions,
            "tests": list(self._tests.values()),
        }
        path.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        # viewer.html を file:// で直接開く用（fetch は file:// では CORS で使えないため <script src> で読む）
        (self.out_dir / "journey.js").write_text(
            "window.JOURNEY_DATA = " + json.dumps(data, ensure_ascii=False) + ";\n",
            encoding="utf-8")
        # ビューアー本体も同梱: <out_dir>/viewer.html をダブルクリックするだけで
        # journey.js＋スクショを相対解決して開ける（レポート生成やパス指定が不要な最短ルート）
        _deploy_viewer(self.out_dir)
        return path

    # -------------------------------------------------------------- internal

    def _record_action(self, kind: str, path: str) -> None:
        if not self.enabled:
            return
        if kind in ("tap", "ngui_tap"):
            self._pending_via = path
        if self.current_test:
            self._pending_actions.setdefault(self.current_test, []).append(
                {"kind": kind, "screen": self._current_screen, "path": path})

    def _add_transition(self, from_id: str, to_id: str, via: str | None) -> None:
        for t in self._transitions:
            if t["from"] == from_id and t["to"] == to_id and t["via"] == via:
                if t.get("test") is None:
                    t["test"] = self.current_test
                return
        self._transitions.append(
            {"from": from_id, "to": to_id, "via": via, "test": self.current_test})

    def _collect_app_info(self) -> dict:
        info = self.client.ping()
        result = {k: info[k] for k in ("package", "app", "unity", "bridge", "screen")
                  if k in info}
        # 同時接続（複数デバイス/アプリ）をビューアー上で識別できるよう接続先も記録する
        device = os.environ.get("UAPP_E2E_DEVICE_SERIAL")
        if device:
            result["device"] = device
        host = getattr(self.client, "host", None)
        port = getattr(self.client, "port", None)
        if host and port:
            result["bridgeHost"] = f"{host}:{port}"
        return result

    def _screencap(self, screen_id: str) -> str | None:
        rel = f"screens/{_safe_name(screen_id)}.png"
        try:
            adb.screencap(self.out_dir / rel)
            return rel
        except Exception:
            return None  # エディタ直結など adb の無い環境ではスクショなしで記録する

    def _load(self) -> None:
        path = self.out_dir / "journey.json"
        if not path.exists():
            return
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("format") != FORMAT:
            raise ValueError(f"未対応のジャーニー形式です: {data.get('format')} ({path})")
        self._app = data.get("app")
        self._screens = {s["id"]: s for s in data.get("screens", [])}
        self._transitions = data.get("transitions", [])
        self._tests = {t["name"]: t for t in data.get("tests", [])}


class RecordingGestures:
    """Gestures のプロキシ。成功した操作をレコーダーに記録してから制御を返す。

    記録対象外のメソッド（wait_* 等）はそのまま委譲する。
    """

    def __init__(self, recorder: JourneyRecorder, gestures: Gestures):
        self._recorder = recorder
        self._gestures = gestures

    def tap(self, path: str, pointer_id: int | None = None) -> None:
        self._gestures.tap(path, pointer_id)
        self._recorder._record_action("tap", path)

    def ngui_tap(self, path: str) -> None:
        self._gestures.ngui_tap(path)
        self._recorder._record_action("ngui_tap", path)

    def press(self, path: str, pointer_id: int) -> None:
        self._gestures.press(path, pointer_id)
        self._recorder._record_action("press", path)

    def ngui_press(self, path: str) -> None:
        self._gestures.ngui_press(path)
        self._recorder._record_action("ngui_press", path)

    def pinch(self, center_path: str | None = None, **kwargs: Any) -> None:
        self._gestures.pinch(center_path, **kwargs)
        if center_path:
            self._recorder._record_action("pinch", center_path)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._gestures, name)


def _deploy_viewer(out_dir: Path) -> None:
    """viewer.html の最新テンプレートを journey ディレクトリへ配置する。

    既存コピーが内容違い（旧テンプレ or 独自改修）の場合は黙って消さず、
    viewer-backup-<日時>.html へ退避してから更新する。
    """
    template = Path(__file__).parent / "viewer.html"
    if not template.exists():
        return
    dest = out_dir / "viewer.html"
    new_content = template.read_bytes()
    if dest.exists():
        current = dest.read_bytes()
        if current == new_content:
            return
        backup = out_dir / f"viewer-backup-{datetime.now().strftime('%Y%m%d-%H%M%S')}.html"
        shutil.copyfile(dest, backup)
    dest.write_bytes(new_content)


# ------------------------------------------------------------------ reporting

def export_html(journey: str | Path, out_path: str | Path | None = None) -> Path:
    """journey.json とスクリーンショットを viewer.html に埋め込んだ自己完結レポートを生成する。"""
    journey_path = Path(journey)
    if journey_path.is_dir():
        journey_path = journey_path / "journey.json"
    data = json.loads(journey_path.read_text(encoding="utf-8"))
    if data.get("format") != FORMAT:
        raise ValueError(f"未対応のジャーニー形式です: {data.get('format')} ({journey_path})")

    base = journey_path.parent
    for screen in data.get("screens", []):
        rel = screen.get("screenshot")
        if rel and (base / rel).exists():
            png = (base / rel).read_bytes()
            screen["screenshot"] = "data:image/png;base64," + base64.b64encode(png).decode()
        else:
            screen["screenshot"] = None

    template = (Path(__file__).parent / "viewer.html").read_text(encoding="utf-8")
    if _DATA_SLOT not in template:
        raise RuntimeError("viewer.html にデータ差し込みスロットが見つかりません")
    # 文字列中に </script> が現れて HTML を壊さないよう "</" をエスケープ（JSONとして等価）
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    html = template.replace(_DATA_SLOT, _DATA_SLOT.replace("null", payload, 1), 1)

    out = Path(out_path) if out_path else base / "report.html"
    out.write_text(html, encoding="utf-8")
    return out


# ------------------------------------------------------- 探索モード（serve）

def _match_screen(screens: dict[str, dict], button_paths: set[str],
                  threshold: float = 0.9) -> str | None:
    """ボタンパス集合の類似度（Jaccard）で既知画面に照合する。一致なしなら None。"""
    best_id, best_score = None, 0.0
    for sid, screen in screens.items():
        known = {b["path"] for b in screen.get("buttons", [])}
        union = button_paths | known
        score = (len(button_paths & known) / len(union)) if union else 1.0
        if score > best_score:
            best_id, best_score = sid, score
    return best_id if best_score >= threshold else None


def _find_config_start(journey_dir: Path) -> Path:
    """serve のポート解決に使う e2e-config.json の探索起点を決める。

    導入先レイアウト（<プロジェクト>/uapp_e2e/Builds/journey）は祖先に config があるので
    そのまま journey_dir。開発リポジトリ（Builds/journey/<サンプル名>）は config が
    兄弟の <サンプル名>/e2e-config.json にあるため、同名フォルダも候補に入れる。
    """
    ancestors = [journey_dir, *list(journey_dir.parents)[:4]]
    if any((p / "e2e-config.json").exists() for p in ancestors):
        return journey_dir
    for p in ancestors[1:]:
        candidate = p / journey_dir.name / "e2e-config.json"
        if candidate.exists() and candidate.parent != journey_dir:
            return candidate.parent
    return journey_dir


def _find_ui_type(journey_dir: Path) -> str | None:
    """journey ディレクトリから親を辿って e2e-config.json の uiType を拾う（無ければ None）。"""
    for parent in [journey_dir, *list(journey_dir.parents)[:4]]:
        config = parent / "e2e-config.json"
        if config.exists():
            try:
                return json.loads(config.read_text(encoding="utf-8")).get("uiType")
            except Exception:
                return None
    return None


def _capture_current(recorder: JourneyRecorder, client: BridgeClient) -> str:
    """実機の現在画面を既知画面に照合して取り込む。未知なら screen-N として新規記録する。

    呼び出し前の _current_screen を保たない（遷移を作らずに現状を記録するための入口）。
    """
    recorder._current_screen = None
    current = {b["path"] for b in _extract_buttons(client.dump().get("nodes", []))}
    screen_id = _match_screen(recorder._screens, current)
    if screen_id is None:
        n = 1
        while f"screen-{n}" in recorder._screens:
            n += 1
        screen_id = f"screen-{n}"
        recorder.capture(screen_id, label=f"画面{n}（自動取得）")
    else:
        recorder.capture(screen_id)  # スクショと把握状況を最新化
    return screen_id


def probe_button(out_dir: Path, screen_id: str, path: str, *,
                 bridge_host: str = "127.0.0.1", bridge_port: int | None = None,
                 ui_type: str | None = None) -> dict:
    """ビューアーの「▶ タップ」1回分: 実機の現在画面を照合してからタップし、遷移先を記録する。

    宣言された画面が実機に表示されていなければ**操作せず**、実機の現状を取り込んで返す。
    遷移先は dump のボタンパス集合を既知画面と照合し、一致すればその画面へ、
    未知なら新しい画面（probe-<ボタン名>）としてキャプチャする。
    """
    client = BridgeClient(bridge_host, bridge_port).connect(retries=3, interval=1.0)
    started = time.monotonic()
    try:
        recorder = JourneyRecorder(client, out_dir)
        gestures = recorder.wrap(Gestures(client))
        test_name = f"viewer-probe::{path.split('/')[-1]}"
        recorder.current_test = test_name
        actual = _capture_current(recorder, client)
        if actual != screen_id:
            label = recorder._screens[actual].get("label", actual)
            return {"ok": False, "mismatch": True, "actual": actual, "actualLabel": label,
                    "from": screen_id, "to": None, "test": None, "outcome": None,
                    "error": f"実機はいま「{label}」を表示しています（この画面ではありません）"}
        recorder._current_screen_test = test_name
        outcome, error, to_id = "passed", None, None
        try:
            if ui_type == "ngui-legacy":
                gestures.ngui_tap(path)
            else:
                gestures.tap(path)
            time.sleep(1.5)
        except Exception as e:
            outcome, error = "failed", f"{type(e).__name__}: {e}"
        if outcome == "passed":
            after = {b["path"] for b in _extract_buttons(client.dump().get("nodes", []))}
            to_id = _match_screen(recorder._screens, after)
            if to_id is None:
                to_id = f"probe-{_safe_name(path.split('/')[-1])}"
                recorder.capture(to_id, label=f"{path.split('/')[-1]} の先（探索）")
            else:
                recorder.capture(to_id)  # 既知画面: 再キャプチャで遷移とスクショを更新
        recorder.record_test(test_name, outcome, round(time.monotonic() - started, 2))
        return {"ok": outcome == "passed", "outcome": outcome, "error": error,
                "from": screen_id, "to": to_id, "test": test_name}
    finally:
        client.close()


def serve(journey_dir: str | Path, *, http_port: int = 8787,
          bridge_host: str = "127.0.0.1", bridge_port: int | None = None,
          ui_type: str | None = None, open_browser: bool = True) -> None:
    """journey ディレクトリを http 配信し、ビューアーからの探索タップ（/api/probe）を受ける。"""
    out_dir = Path(journey_dir).resolve()
    if not (out_dir / "journey.json").exists():
        raise FileNotFoundError(f"journey.json が見つかりません: {out_dir}")
    _deploy_viewer(out_dir)  # 最新ビューアーで配信する（既存コピーが内容違いなら退避してから）
    # config 探索は journey ディレクトリ起点（実行場所に依存させない）。uiType とポートは
    # 同じ e2e-config.json から解決する（開発リポジトリ配置では兄弟のサンプルプロジェクト）
    config_start = _find_config_start(out_dir)
    resolved_ui_type = ui_type or _find_ui_type(config_start)
    bridge_port = resolve_port(bridge_port, start=config_start)

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(out_dir), **kwargs)

        def log_message(self, fmt, *args):  # 静かに（probe結果は都度printする）
            pass

        def _send_json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/api/ping":
                self._send_json(200, {"ok": True, "uiType": resolved_ui_type})
                return
            super().do_GET()

        def do_POST(self):
            try:
                if self.path == "/api/probe":
                    length = int(self.headers.get("Content-Length", "0"))
                    req = json.loads(self.rfile.read(length) or b"{}")
                    result = probe_button(out_dir, req["screen"], req["path"],
                                          bridge_host=bridge_host, bridge_port=bridge_port,
                                          ui_type=resolved_ui_type)
                    print(f"[probe] {req['path']} → {result.get('to')} "
                          f"({result.get('outcome') or result.get('error')})")
                    self._send_json(200, result)
                elif self.path == "/api/sync":
                    client = BridgeClient(bridge_host, bridge_port).connect(retries=3, interval=1.0)
                    try:
                        recorder = JourneyRecorder(client, out_dir)
                        sid = _capture_current(recorder, client)
                        label = recorder._screens[sid].get("label", sid)
                    finally:
                        client.close()
                    print(f"[sync] 実機画面を取り込み: {sid}")
                    self._send_json(200, {"ok": True, "to": sid, "label": label})
                else:
                    self._send_json(404, {"ok": False, "error": "unknown endpoint"})
            except Exception as e:
                print(f"[api] エラー: {e}")
                self._send_json(500, {"ok": False, "error": f"{type(e).__name__}: {e}"})

    server = HTTPServer(("127.0.0.1", http_port), Handler)
    url = f"http://127.0.0.1:{http_port}/viewer.html"
    # ダブルクリックで開けるショートカットを journey ディレクトリに置く（URLの発見手段）
    (out_dir / "探索モード.url").write_text(f"[InternetShortcut]\nURL={url}\n", encoding="ascii")
    print(f"探索モード: {url}")
    print(f"  journey: {out_dir}")
    print(f"  bridge: {bridge_host}:{bridge_port}"
          f" / uiType: {resolved_ui_type or '不明（tap系を使用）'}  [Ctrl+C で停止]")
    if open_browser:
        webbrowser.open(url)
    server.serve_forever()


def main(argv: list[str] | None = None) -> None:
    import sys
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "serve":
        parser = argparse.ArgumentParser(
            prog="python -m e2e_driver.journey serve",
            description="ビューアーを http 配信し、未テストボタンの探索タップを受け付ける")
        parser.add_argument("journey", help="journey.json を含むディレクトリ")
        parser.add_argument("--http-port", type=int, default=8787)
        parser.add_argument("--bridge-host", default="127.0.0.1")
        parser.add_argument("--bridge-port", type=int, default=None,
                            help="ブリッジのホスト側ポート（既定: 環境変数 UAPP_E2E_BRIDGE_PORT → "
                                 "e2e-config.json の editorBridgePort → 13333）")
        parser.add_argument("--ui-type", default=None,
                            help="ngui-legacy を指定すると ngui_tap を使う（既定: e2e-config.json から自動判定）")
        parser.add_argument("--no-open", action="store_true",
                            help="起動時にブラウザを自動で開かない（AI・CI用）")
        args = parser.parse_args(argv[1:])
        serve(args.journey, http_port=args.http_port, bridge_host=args.bridge_host,
              bridge_port=args.bridge_port, ui_type=args.ui_type,
              open_browser=not args.no_open)
        return
    parser = argparse.ArgumentParser(
        description="journey.json から自己完結HTMLレポート（report.html）を生成する。"
                    "探索モードは `serve <dir>` サブコマンド")
    parser.add_argument("journey", help="journey.json またはそれを含むディレクトリ")
    parser.add_argument("-o", "--out", default=None, help="出力先HTML（既定: journey隣の report.html）")
    args = parser.parse_args(argv)
    print(f"generated: {export_html(args.journey, args.out)}")


if __name__ == "__main__":
    main()
