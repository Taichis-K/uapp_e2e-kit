"""UI を経由しない入力（キーボード / マウス / ゲームパッド）の操作ヘルパー。

`Gestures` はタッチ（＋ uGUI の到達可能性検証）専用なので分けている。責務が違う:

- `Gestures.tap(path)` … 「その UI を実ユーザーがタップできるか」まで検証してから押す
- ここ                … 「キーが押された」「パッドのボタンが押された」を**そのまま起こす**

押しっぱなし（歩き続ける・ボタンホールド）は down/up を分けて使う。
テストの後始末は `reset()`（押しっぱなしを持ち越すと次のテストが原因不明で壊れる）。

    from e2e_driver import Keyboard, Mouse, Gamepad

    kb = Keyboard(client)
    kb.press("space")                 # 押して離す
    kb.down("w"); ...; kb.up("w")     # 押しっぱなし

    Mouse(client).click(540, 1200)
    Gamepad(client).press("buttonSouth")
    Gamepad(client).stick("left", 0, 1)   # 前に倒す
"""
from __future__ import annotations

import time

from .client import BridgeClient

# 注入は次のフレームで処理される。押した直後に離すと、アプリが 1 フレームも
# 「押されている」状態を観測できないことがある（Update で拾う実装が普通）
FRAME_WAIT = 0.05


class _Device:
    def __init__(self, client: BridgeClient, frame_wait: float = FRAME_WAIT):
        self.client = client
        self.frame_wait = frame_wait

    def _settle(self) -> None:
        time.sleep(self.frame_wait)

    def reset(self) -> dict:
        """このセッションで押しっぱなしのキー・ボタンを全部離す。"""
        return self.client.input_reset()


class Keyboard(_Device):
    def down(self, key: str) -> dict:
        result = self.client.key_down(key)
        self._settle()
        return result

    def up(self, key: str) -> dict:
        result = self.client.key_up(key)
        self._settle()
        return result

    def press(self, key: str, hold: float = 0.0) -> None:
        """押して離す。`hold` を指定すると押しっぱなしの時間を作る（長押し判定用）。"""
        self.down(key)
        if hold:
            time.sleep(hold)
        self.up(key)


class Mouse(_Device):
    def move(self, x: float, y: float) -> dict:
        result = self.client.mouse_move(x, y)
        self._settle()
        return result

    def down(self, button: str = "left", x: float | None = None, y: float | None = None) -> dict:
        result = self.client.mouse_down(button, x, y)
        self._settle()
        return result

    def up(self, button: str = "left") -> dict:
        result = self.client.mouse_up(button)
        self._settle()
        return result

    def click(self, x: float | None = None, y: float | None = None,
              button: str = "left", hold: float = 0.0) -> None:
        """座標を指定してクリックする（省略時は現在位置）。"""
        if x is not None and y is not None:
            self.move(x, y)
        self.down(button)
        if hold:
            time.sleep(hold)
        self.up(button)

    def scroll(self, dy: float, dx: float = 0.0) -> dict:
        result = self.client.mouse_scroll(dx, dy)
        self._settle()
        return result


class Gamepad(_Device):
    def down(self, button: str) -> dict:
        result = self.client.pad_button_down(button)
        self._settle()
        return result

    def up(self, button: str) -> dict:
        result = self.client.pad_button_up(button)
        self._settle()
        return result

    def press(self, button: str, hold: float = 0.0) -> None:
        self.down(button)
        if hold:
            time.sleep(hold)
        self.up(button)

    def stick(self, stick: str = "left", x: float = 0.0, y: float = 0.0, hold: float = 0.0) -> dict:
        """スティックを倒す。`hold` 後に中立へ戻す（倒しっぱなしにするなら hold=0 で放置）。"""
        result = self.client.pad_stick(stick, x, y)
        self._settle()
        if hold:
            time.sleep(hold)
            self.client.pad_stick(stick, 0.0, 0.0)
            self._settle()
        return result
