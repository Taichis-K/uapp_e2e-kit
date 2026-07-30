"""E2EBridge（Unityアプリ内計装サーバー）への行区切りJSONクライアント。

座標系はすべて Unity スクリーン座標（左下原点・ピクセル）。
接続先ポートは 明示引数 > 環境変数 UAPP_E2E_BRIDGE_PORT > e2e-config.json の
editorBridgePort > 13333 の順で解決する（resolve_port 参照）。
"""
from __future__ import annotations

import json
import os
import re
import socket
import time
import warnings
from pathlib import Path
from typing import Any

DEFAULT_PORT = 13333

_PORT_RE = re.compile(r"[+-]?[0-9]+")


def _parse_port(raw) -> int | None:
    """C#側（int.TryParse）と受理範囲を揃えた厳格なポート解釈。値域は 1〜65535。

    Python の int() は "13_333" や bool（True→1）も通してしまい、Unity 側と
    「どちらか片方だけ採用」の不整合を生むため、符号＋10進数字のみを受理する。
    不採用は None（呼び出し側が次の候補へフォールバックする）。
    """
    if isinstance(raw, bool):
        return None
    if isinstance(raw, int):
        port = raw
    elif isinstance(raw, str) and _PORT_RE.fullmatch(raw.strip()):
        port = int(raw.strip())
    else:
        return None
    return port if 1 <= port <= 65535 else None


def _env_port(name: str) -> int | None:
    """環境変数から検証済みポートを取得。未設定は None、無効値は警告して None。"""
    raw = os.environ.get(name)
    if not raw:
        return None
    port = _parse_port(raw)
    if port is None:
        warnings.warn(f"{name}={raw} は有効なポート（1〜65535の10進整数）でないため無視します")
    return port


def _config_editor_port(start: Path | None = None) -> int | None:
    """start（既定: カレントディレクトリ）から親を辿って e2e-config.json の editorBridgePort を拾う。

    ポート未指定の BridgeClient() の典型用途はエディタ再生への直結
    （デバイス向けは run-e2e.ps1 が UAPP_E2E_BRIDGE_PORT で forward 先を渡してくる）。
    設定が無い・読めない・値の型が想定外の場合は None（既定値へフォールバック）。
    """
    start = Path(start) if start is not None else Path.cwd()
    for parent in [start, *list(start.parents)[:4]]:
        config = parent / "e2e-config.json"
        if config.exists():
            try:
                value = json.loads(config.read_text(encoding="utf-8")).get("editorBridgePort")
                if value is None:
                    return None
                port = _parse_port(value)
                if port is None:
                    warnings.warn(f"{config} の editorBridgePort={value!r} は有効なポートでないため無視します")
                return port
            except Exception:
                return None
    return None


def resolve_port(explicit: int | None = None, start: Path | None = None) -> int:
    """接続先ホストポートの解決: 明示引数 > UAPP_E2E_BRIDGE_PORT > e2e-config.json > 13333。

    start は e2e-config.json の探索起点（既定: カレントディレクトリ）。
    値域は 1〜65535（BridgeHost.ResolvePort と同一）。環境変数・設定ファイルの値域外/不正値は
    警告して次の候補へスキップし、Unity 側と接続先がズレないようにする。
    明示引数の値域外だけは ValueError — 暗黙フォールバックすると呼び出し側の意図と
    別のポートへ接続してしまうため、即時に失敗させる。
    """
    if explicit is not None:
        port = _parse_port(explicit)
        if port is None:
            raise ValueError(f"port {explicit!r} は有効なポートではありません（1〜65535の10進整数）")
        return port
    env_port = _env_port("UAPP_E2E_BRIDGE_PORT")
    if env_port is not None:
        return env_port
    config_port = _config_editor_port(start)
    if config_port is not None:
        return config_port
    return DEFAULT_PORT


class BridgeError(Exception):
    """ブリッジが返したプロトコルエラー。code で機械的に分岐できる。"""

    def __init__(self, code: str, message: str):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message


class BlockedError(Exception):
    """タップ対象に実タッチが届かない。理由は `blocked_by` に入る。

    **待てば解ける遮蔽と、待っても永久に押せない状態を区別する**。混ぜると
    `wait_until_hittable` でタイムアウトまで待つ無駄が起きる（実導入で報告）。
    """

    #: 待っても解決しない理由（対象自身の問題）。それ以外は遮蔽オブジェクトのパス
    HOPELESS = {
        "NOT_RAYCASTABLE": "対象（と子孫）に raycast を受ける要素が無い。指しているパスが違う",
        "NO_EVENTSYSTEM": "シーンに EventSystem が無い",
        "INACTIVE": "対象が非アクティブ",
    }

    def __init__(self, path: str, blocked_by: str):
        hint = self.HOPELESS.get(blocked_by)
        detail = f"'{path}' is blocked by '{blocked_by}'"
        if hint:
            detail += f" — {hint}（待っても変わらない）"
        super().__init__(detail)
        self.path = path
        self.blocked_by = blocked_by

    @property
    def hopeless(self) -> bool:
        """待っても解決しない種類か（呼び手が再試行の要否を判断できる）。"""
        return self.blocked_by in self.HOPELESS


class BridgeClient:
    def __init__(self, host: str = "127.0.0.1", port: int | None = None, timeout: float = 30.0):
        self.host = host
        self.port = resolve_port(port)
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._file = None
        self._next_id = 1

    # ------------------------------------------------------------ connection

    def connect(self, retries: int = 30, interval: float = 1.0) -> "BridgeClient":
        """アプリ起動直後を考慮してリトライしながら接続する。"""
        last_error: Exception | None = None
        for _ in range(retries):
            try:
                self._sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
                self._file = self._sock.makefile("r", encoding="utf-8", newline="\n")
                self.ping()  # 疎通確認
                return self
            except (OSError, BridgeError) as e:
                last_error = e
                self.close()
                time.sleep(interval)
        raise ConnectionError(
            f"E2EBridge ({self.host}:{self.port}) に接続できません。"
            f"アプリ（またはエディタ再生）の起動、デバイス接続なら adb forward を確認してください: {last_error}"
        )

    def close(self) -> None:
        for closable in (self._file, self._sock):
            try:
                if closable:
                    closable.close()
            except OSError:
                pass
        self._file = None
        self._sock = None

    def __enter__(self) -> "BridgeClient":
        return self.connect()

    def __exit__(self, *_exc) -> None:
        self.close()

    # --------------------------------------------------------------- protocol

    def call(self, cmd: str, **args: Any) -> Any:
        if self._sock is None:
            raise ConnectionError("not connected. call connect() first")
        request = {"id": self._next_id, "cmd": cmd, "args": args}
        self._next_id += 1
        self._sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
        line = self._file.readline()
        if not line:
            raise ConnectionError("bridge closed the connection")
        response = json.loads(line)
        if not response.get("ok"):
            error = response.get("error", {})
            raise BridgeError(error.get("code", "UNKNOWN"), error.get("message", ""))
        return response.get("result")

    # --------------------------------------------------------------- commands

    def ping(self) -> dict:
        return self.call("ping")

    def dump(self, scope: str = "ui", probe: str = "selectable", path: str | None = None) -> dict:
        args: dict[str, Any] = {"scope": scope, "probe": probe}
        if path:
            args["path"] = path
        return self.call("dump", **args)

    def resolve(self, path: str) -> dict:
        return self.call("resolve", path=path)

    def get(self, path: str, component: str, prop: str) -> Any:
        return self.call("get", path=path, component=component, property=prop)["value"]

    def pointer_down(self, pointer_id: int, x: float, y: float) -> dict:
        return self.call("pointer_down", pointerId=pointer_id, x=x, y=y)

    def pointer_move(self, pointer_id: int, x: float, y: float) -> dict:
        return self.call("pointer_move", pointerId=pointer_id, x=x, y=y)

    def pointer_up(self, pointer_id: int) -> dict:
        return self.call("pointer_up", pointerId=pointer_id)

    def pointer_reset(self) -> dict:
        return self.call("pointer_reset")

    # --- UI を経由しない入力（キー / マウス / ゲームパッド）------------------
    # hittable 判定は関係しない。アプリが InputAction で読んでいても
    # デバイスを直読みしていても、実入力と同じ経路で届く。
    # レガシー入力バックエンドのみの構成では INPUT_BACKEND_LEGACY で明示的に失敗する

    def key_down(self, key: str) -> dict:
        return self.call("key_down", key=key)

    def key_up(self, key: str) -> dict:
        return self.call("key_up", key=key)

    def mouse_move(self, x: float, y: float) -> dict:
        return self.call("mouse_move", x=x, y=y)

    def mouse_down(self, button: str = "left", x: float | None = None, y: float | None = None) -> dict:
        args: dict[str, Any] = {"button": button}
        if x is not None and y is not None:
            args.update(x=x, y=y)
        return self.call("mouse_down", **args)

    def mouse_up(self, button: str = "left") -> dict:
        return self.call("mouse_up", button=button)

    def mouse_scroll(self, dx: float = 0.0, dy: float = 0.0) -> dict:
        return self.call("mouse_scroll", dx=dx, dy=dy)

    def pad_button_down(self, button: str) -> dict:
        return self.call("pad_button_down", button=button)

    def pad_button_up(self, button: str) -> dict:
        return self.call("pad_button_up", button=button)

    def pad_stick(self, stick: str = "left", x: float = 0.0, y: float = 0.0) -> dict:
        return self.call("pad_stick", stick=stick, x=x, y=y)

    def input_reset(self) -> dict:
        """押しっぱなしを全部離す（テスト間で状態を持ち越さない）。"""
        return self.call("input_reset")

    def input_devices(self) -> dict:
        """接続中の入力デバイス一覧。**実機が刺さっているか**を確認するために使う。

        エディタ実行の PC には本物のキーボード・マウス・ゲームパッドが同時に居る。
        注入は専用の仮想デバイスへ行うが、人が実機を触れば `current` は奪われる。
        原因不明の不安定さにしないよう、`realGamepads` 等で最初から見えるようにしている。

        **仮想デバイスは種別ごとに「初回注入時」に生成される（遅延生成）。**
        つまり `key_down` / `mouse_move` / `pad_stick` を一度も呼んでいない種別は
        `devices` に出てこない。**これは実機に注入しているのではない**（注入先は常に仮想デバイス）。
        どの種別が生成済みかは `virtualDevices` を見る:

            {"virtualDevices": [{"kind": "mouse", "name": "E2EVirtualMouse", "created": false}, ...]}

        `devices` を名前で引くコードは、注入前だと KeyError になる（導入先で実際に踏まれた）。
        注入後に取り直すか、`virtualDevices` の `created` を見ること。
        """
        return self.call("input_devices")

    def ngui_event(self, path: str, event: str = "click") -> dict:
        """NGUI向けフレームワークレベルイベント送出（click | press | release）。

        レガシーInput構成のNGUIアプリ（Touchscreen注入が届かない）で使う。
        到達可能性は検証しないため、通常は Gestures.ngui_tap 経由で使うこと。
        """
        return self.call("ngui_event", path=path, event=event)

