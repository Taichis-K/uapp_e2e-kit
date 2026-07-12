"""E2EBridge（Unityアプリ内計装サーバー）への行区切りJSONクライアント。

座標系はすべて Unity スクリーン座標（左下原点・ピクセル）。
接続先は adb forward tcp:13333 tcp:13333 済みの localhost:13333 を想定。
"""
from __future__ import annotations

import json
import os
import socket
import time
from typing import Any


class BridgeError(Exception):
    """ブリッジが返したプロトコルエラー。code で機械的に分岐できる。"""

    def __init__(self, code: str, message: str):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message


class BlockedError(Exception):
    """タップ対象が他のUI（全画面ブロッカー等）に遮られている。"""

    def __init__(self, path: str, blocked_by: str):
        super().__init__(f"'{path}' is blocked by '{blocked_by}'")
        self.path = path
        self.blocked_by = blocked_by


class BridgeClient:
    def __init__(self, host: str = "127.0.0.1", port: int | None = None, timeout: float = 30.0):
        if port is None:
            # ホスト側ポート（config/local.json の bridgePort → run-e2e.ps1 が環境変数で渡す）
            port = int(os.environ.get("UAPP_E2E_BRIDGE_PORT", "13333"))
        self.host = host
        self.port = port
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
            f"アプリ起動と adb forward を確認してください: {last_error}"
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

    def ngui_event(self, path: str, event: str = "click") -> dict:
        """NGUI向けフレームワークレベルイベント送出（click | press | release）。

        レガシーInput構成のNGUIアプリ（Touchscreen注入が届かない）で使う。
        到達可能性は検証しないため、通常は Gestures.ngui_tap 経由で使うこと。
        """
        return self.call("ngui_event", path=path, event=event)

