"""pointer_down/move/up プリミティブから合成する高レベルジェスチャと待機ヘルパー。

タップは「実ユーザーが届くか」を resolve の hittable で必ず検証してから行う。
遮られている場合は BlockedError（遮蔽オブジェクトのパス付き）を投げるので、
AI はそれを見て「バグ」か「先に閉じるべきUIがある」かを判断できる。
"""
from __future__ import annotations

import math
import time

from .client import BlockedError, BridgeClient, BridgeError


class WaitTimeout(AssertionError):
    pass


class Gestures:
    # ポインタIDの予約: 1-4 は単発操作、8-9 はピンチ用
    TAP_POINTER = 1
    PINCH_POINTERS = (8, 9)

    def __init__(self, client: BridgeClient, frame_wait: float = 0.05):
        self.client = client
        self.frame_wait = frame_wait  # down と up の間に挟む待ち（フレームをまたがせる）

    # ------------------------------------------------------------------ tap

    def tap(self, path: str, pointer_id: int | None = None) -> None:
        """hittable を検証してからタップする。遮蔽時は BlockedError。"""
        center = self._require_hittable(path)
        pid = pointer_id or self.TAP_POINTER
        self.client.pointer_down(pid, center[0], center[1])
        time.sleep(self.frame_wait)
        self.client.pointer_up(pid)

    def press(self, path: str, pointer_id: int) -> None:
        """押しっぱなしにする（release まで保持）。マルチタッチシナリオ用。"""
        center = self._require_hittable(path)
        self.client.pointer_down(pointer_id, center[0], center[1])
        time.sleep(self.frame_wait)

    def release(self, pointer_id: int) -> None:
        self.client.pointer_up(pointer_id)
        time.sleep(self.frame_wait)

    # ----------------------------------------------------------------- ngui
    # レガシーInput構成のNGUIアプリ向け（Touchscreen注入が届かないため、
    # UICamera.Raycastによる到達可能性検証 + UICamera.Notifyによるイベント送出で代替する）。
    # NGUI+NewInputSystem構成のアプリでは通常の tap / press / pinch がそのまま使える。

    def ngui_tap(self, path: str) -> None:
        """NGUIタップ。hittable（UICamera.Raycast）を検証してからOnPress/OnClickを送出。"""
        self._require_hittable(path)
        self.client.ngui_event(path, "click")
        time.sleep(self.frame_wait)

    def ngui_press(self, path: str) -> None:
        self._require_hittable(path)
        self.client.ngui_event(path, "press")
        time.sleep(self.frame_wait)

    def ngui_release(self, path: str) -> None:
        self.client.ngui_event(path, "release")
        time.sleep(self.frame_wait)

    # ----------------------------------------------------------------- ugui
    # レガシーInput構成のuGUIアプリ向け（Active Input Handling が Input Manager (Old)）。
    # その構成では Touchscreen 注入を誰も読まないので tap / press / pinch が届かない。
    # ヒットテストは通常の tap と同じ RaycastProbe（EventSystem.RaycastAll）なので、
    # 変わるのは送出側だけ＝ wait_until_hittable もそのまま使える。
    # uGUI+NewInputSystem 構成のアプリでは通常の tap / press / pinch がそのまま使える。

    def ugui_tap(self, path: str, pointer_id: int | None = None) -> None:
        """uGUIタップ。hittable を検証してから pointerDown/Up/Click を送出。

        **応答の `hittable` も確かめる**。`ugui_event` は遮蔽されていても送出するので、
        事前検証と送出の間に遮蔽が割り込む遷移（ローディング膜が出た等）を
        見ないと、押せていないのに緑になる。実タップ（`tap`）との挙動差でもある。
        """
        self._require_hittable(path)
        result = self.client.ugui_event(path, "click", pointer_id or self.TAP_POINTER)
        if result.get("hittable") is False:
            raise BlockedError(path, result.get("blockedBy") or "UNKNOWN")
        time.sleep(self.frame_wait)

    def ugui_press(self, path: str, pointer_id: int | None = None, *,
                   x: float | None = None, y: float | None = None) -> None:
        """押しっぱなしにする（release まで保持）。

        **pointer_id を分ければ複数の指を同時に置ける**（A を押しながら B をタップ）。
        ドラッグの起点にも使う。応答の `hittable` も確かめる（ugui_tap と同じ理由）。

        **x/y を渡すと、押す位置をその座標にする**（既定は path の中心）。
        **座標を渡したときは事前の中心ヒットテストをしない** ―
        中心が別の要素に取られていること自体が座標を指定する理由なので、
        そこで弾いては用を成さない（ScrollRect の中央にスライダーが載っている等）。
        かわりに**押下の応答で確かめる**: ブリッジは x/y があれば**その座標で**ヒットテストし、
        **当たった実体へ送る**（当たらなければ path の要素へ）ので、応答の `hittable` は
        「その座標で本当に届いたか」を表す。
        """
        pid = pointer_id or self.TAP_POINTER
        if x is None and y is None:
            self._require_hittable(path)
        result = self.client.ugui_event(path, "press", pid, x=x, y=y)
        if result.get("hittable") is False:
            # 押下は成立しているので、掴んだままにしない
            self.client.ugui_event(event="release", pointer_id=pid)
            raise BlockedError(path, result.get("blockedBy") or "UNKNOWN")
        time.sleep(self.frame_wait)

    def ugui_move(self, x: float, y: float, pointer_id: int | None = None) -> None:
        """押下中のポインタを動かす（ScrollRect / Slider のドラッグ用）。"""
        self.client.ugui_event(event="move", pointer_id=pointer_id or self.TAP_POINTER, x=x, y=y)
        time.sleep(self.frame_wait)

    def ugui_release(self, path: str | None = None, pointer_id: int | None = None) -> None:
        """離す。path を渡すとその位置まで動かしてから離す（drag & drop）。"""
        self.client.ugui_event(path, "release", pointer_id or self.TAP_POINTER)
        time.sleep(self.frame_wait)

    def ugui_drag(self, path: str, x2: float, y2: float, *, steps: int = 8,
                  hold: float = 0.0, pointer_id: int | None = None) -> None:
        """path の中心から (x2, y2) まで、押下したまま段階的に動かして離す。

        **段階を刻むのは ScrollRect の慣性や Slider の追従が 1 手では出ないため**
        （実タップの drag と同じ理由）。

        hold > 0 なら終点で押したまま保持してから離す（実タップの `drag` と同じ）。

        **掴む位置を選びたいときは `ugui_drag_xy`**（中心が別の要素に取られている場合）。
        """
        pid = pointer_id or self.TAP_POINTER
        x1, y1 = self._require_hittable(path)
        self.client.ugui_event(path, "press", pid)
        time.sleep(self.frame_wait)
        self._ugui_drag_steps(pid, x1, y1, x2, y2, steps, hold)

    def ugui_drag_xy(self, path: str, x1: float, y1: float, x2: float, y2: float, *,
                     steps: int = 12, hold: float = 0.0,
                     pointer_id: int | None = None) -> None:
        """(x1, y1) で押し、(x2, y2) まで動かして離す。**掴む位置を座標で決める**（issue #61）。

        `ugui_drag` は path の**中心**から始まるので、**中心が別の要素に取られている**
        ScrollRect では使えない（中央にスライダーやドロップダウンが載っていると、
        そちらがドラッグを消費する）。導入先の実運用では「スクロール領域の左端 +12」のような
        端を掴む必要があった。

        `path` は**イベントの宛先**で、位置は x/y が決める。
        ブリッジは指定座標でヒットテストし、**当たった実体があればそちらへ送る**
        （当たらなければ `path` の要素へ）。
        **事前の中心ヒットテストはしない**理由は `ugui_press` の説明を参照。

        hold > 0 なら終点で押したまま保持してから離す（仮想スティックを倒し続ける等）。
        """
        pid = pointer_id or self.TAP_POINTER
        self.ugui_press(path, pid, x=x1, y=y1)
        self._ugui_drag_steps(pid, x1, y1, x2, y2, steps, hold)

    def _ugui_drag_steps(self, pid: int, x1: float, y1: float, x2: float, y2: float,
                         steps: int, hold: float) -> None:
        """押下済みのポインタを (x2, y2) まで刻んで動かし、必要なら保持して離す。

        **ugui_drag と ugui_drag_xy で共有する**（押し方だけが違い、動かし方は同じ。
        片方にだけ hold を足すような食い違いを作らないため）。
        """
        for i in range(1, steps + 1):
            t = i / steps
            self.client.ugui_event(event="move", pointer_id=pid,
                                   x=x1 + (x2 - x1) * t, y=y1 + (y2 - y1) * t)
            time.sleep(self.frame_wait)
        if hold > 0:
            time.sleep(hold)
        self.client.ugui_event(event="release", pointer_id=pid)
        time.sleep(self.frame_wait)

    # ----------------------------------------------------------------- drag

    def drag(self, x1: float, y1: float, x2: float, y2: float, *,
             duration: float = 0.4, steps: int = 12, hold: float = 0.0,
             pointer_id: int | None = None) -> None:
        """1本指ドラッグ（スワイプ／仮想ジョイスティック操作）。座標はUnityスクリーン座標。

        hold > 0 なら終点で押したまま保持してから離す＝ジョイスティックを倒し続ける
        （キャラ移動は「開始点=スティック位置、終点=倒す方向、hold=歩く時間」で合成する）。
        カメラ回転は hold なしのスワイプでよい。移動しながらの操作は pointer_id を分けて併用する。
        """
        pid = pointer_id or self.TAP_POINTER
        self.client.pointer_down(pid, x1, y1)
        interval = duration / steps
        for i in range(1, steps + 1):
            t = i / steps
            self.client.pointer_move(pid, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
            time.sleep(interval)
        if hold > 0:
            time.sleep(hold)
        self.client.pointer_up(pid)
        time.sleep(self.frame_wait)

    # ---------------------------------------------------------------- pinch

    def pinch(self, center_path: str | None = None, *, cx: float | None = None, cy: float | None = None,
              dist_from: float = 100, dist_to: float = 300, duration: float = 0.5, steps: int = 20,
              angle_deg: float = 0.0) -> None:
        """2本指ピンチ。dist_from < dist_to で拡大、逆で縮小。"""
        if center_path is not None:
            resolved = self.client.resolve(center_path)
            cx, cy = resolved["center"]["x"], resolved["center"]["y"]
        if cx is None or cy is None:
            raise ValueError("center_path か cx/cy のどちらかを指定してください")

        angle = math.radians(angle_deg)
        direction = (math.cos(angle), math.sin(angle))
        p1, p2 = self.PINCH_POINTERS

        def positions(dist: float):
            half = dist / 2
            return (
                (cx - direction[0] * half, cy - direction[1] * half),
                (cx + direction[0] * half, cy + direction[1] * half),
            )

        (x1, y1), (x2, y2) = positions(dist_from)
        self.client.pointer_down(p1, x1, y1)
        self.client.pointer_down(p2, x2, y2)

        interval = duration / steps
        for i in range(1, steps + 1):
            dist = dist_from + (dist_to - dist_from) * (i / steps)
            (x1, y1), (x2, y2) = positions(dist)
            self.client.pointer_move(p1, x1, y1)
            self.client.pointer_move(p2, x2, y2)
            time.sleep(interval)

        self.client.pointer_up(p1)
        self.client.pointer_up(p2)
        time.sleep(self.frame_wait)

    # ---------------------------------------------------------------- waits

    def wait_until_hittable(self, path: str, timeout: float = 10.0, interval: float = 0.1) -> None:
        """hittable になるまで待つ。**待っても解決しない理由なら即座に失敗させる**。

        「そもそも raycast の的でない」対象を待ち続けても状況は変わらない。
        タイムアウトまで待ってから曖昧に失敗すると、AI は原因に辿り着けない（実導入で報告）。
        """
        def hittable_or_hopeless() -> bool:
            resolved = self._resolve_quiet(path)
            if resolved.get("hittable") is True:
                return True
            reason = resolved.get("blockedBy")
            if reason in BlockedError.HOPELESS and reason != "INACTIVE":
                # INACTIVE は表示待ちで解ける。それ以外の対象自身の問題は待っても無駄
                raise BlockedError(path, reason, resolved.get("blockedByComponents"))
            return False

        self._wait(hittable_or_hopeless, timeout, interval, f"'{path}' が hittable になりません")

    def wait_until_visible(self, path: str, timeout: float = 10.0, interval: float = 0.1) -> None:
        self._wait(lambda: self._resolve_quiet(path).get("active") is True,
                   timeout, interval, f"'{path}' が表示されません")

    def wait_until_gone(self, path: str, timeout: float = 10.0, interval: float = 0.1) -> None:
        self._wait(lambda: self._resolve_quiet(path).get("active") is not True,
                   timeout, interval, f"'{path}' が消えません")

    def wait_until(self, condition, timeout: float = 10.0, interval: float = 0.1,
                   message: str = "条件が満たされません") -> None:
        """任意条件の汎用待機（conditionはboolを返すcallable）。"""
        self._wait(condition, timeout, interval, message)

    # -------------------------------------------------------------- private

    def _require_hittable(self, path: str) -> tuple[float, float]:
        resolved = self.client.resolve(path)
        if resolved.get("hittable") is not True:
            raise BlockedError(path, resolved.get("blockedBy", "UNKNOWN"),
                               resolved.get("blockedByComponents"))
        return resolved["center"]["x"], resolved["center"]["y"]

    def _resolve_quiet(self, path: str) -> dict:
        try:
            return self.client.resolve(path)
        except BridgeError as e:
            if e.code == "NOT_FOUND":
                return {}
            raise

    @staticmethod
    def _wait(condition, timeout: float, interval: float, message: str) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(interval)
        raise WaitTimeout(f"{message} (timeout={timeout}s)")
