"""Gestures の合成ロジックをモックで検証する（デバイス不要）。

**ここで見るのは「どの順で・どんな引数で client を叩くか」だけ**で、
実際に ScrollRect が動くかは E2E（test_ugui_legacy.py）の担当。

issue #61（座標指定のドラッグ）を入れたときに新設した。
それまで Gestures のモック単体テストが 1 件も無く、
**座標計算も呼び出し順も実機でしか確かめられなかった**。
"""
from __future__ import annotations

import pytest

from e2e_driver.client import BlockedError
from e2e_driver.gestures import Gestures


class FakeClient:
    """呼び出しを記録するだけの client。resolve の応答はテストごとに差し替える。"""

    def __init__(self, *, hittable: bool = True, center=(100.0, 200.0),
                 press_hittable: bool = True):
        self.calls: list[tuple] = []
        self._hittable = hittable
        self._center = center
        self._press_hittable = press_hittable

    def resolve(self, path: str) -> dict:
        self.calls.append(("resolve", path))
        return {
            "path": path,
            "hittable": self._hittable,
            "blockedBy": None if self._hittable else "Canvas/Shield",
            "center": {"x": self._center[0], "y": self._center[1]},
        }

    def ugui_event(self, path=None, event="click", pointer_id=1, x=None, y=None) -> dict:
        self.calls.append(("ugui_event", path, event, pointer_id, x, y))
        if event == "press":
            return {"hittable": self._press_hittable,
                    "blockedBy": None if self._press_hittable else "Canvas/Slider"}
        return {}

    def events(self) -> list[tuple]:
        return [c for c in self.calls if c[0] == "ugui_event"]


def make(client: FakeClient) -> Gestures:
    # frame_wait=0: 待ちは実装の関心事だが、ここで見たいのは順序と引数
    return Gestures(client, frame_wait=0.0)


# --------------------------------------------------------------- ugui_drag_xy

def test_drag_xy_presses_at_given_point_not_center():
    """**掴む位置は渡した座標**（中心ではない）。これが #61 の本題。

    **`ugui_drag_xy` の始点を保証しているのはここだけ。** E2E では原理的に測れない ―
    press の直後に必ず move が入るので、Slider のように**最終値しか見えない相手**では
    「始点で押したか」を観測できない（mac が変異で実測: 始点を捨てる実装でも E2E は通る）。
    **このテストを緩めると、どの層でも捕まらなくなる。**
    """
    c = FakeClient(center=(500.0, 500.0))
    make(c).ugui_drag_xy("Canvas/ScrollView", 12.0, 300.0, 12.0, 900.0, steps=2)

    press = c.events()[0]
    assert press[1:] == ("Canvas/ScrollView", "press", 1, 12.0, 300.0)


def test_drag_xy_does_not_hittest_the_center():
    """**座標指定のときは中心のヒットテストをしない。**

    中心が別の要素に取られていること自体が座標を指定する理由なので、
    そこで弾いては用を成さない（ScrollRect の中央にスライダーが載っている等）。
    """
    c = FakeClient()
    make(c).ugui_drag_xy("Canvas/ScrollView", 12.0, 300.0, 12.0, 900.0, steps=2)

    assert [k for k, *_ in c.calls if k == "resolve"] == []


def test_drag_from_center_does_hittest_the_center():
    """対照: **座標を渡さない `ugui_drag` は従来どおり中心を検証する。**

    上のテストだけだと「検証を消しただけ」でも通ってしまう。
    """
    c = FakeClient(center=(500.0, 500.0))
    make(c).ugui_drag("Canvas/ScrollView", 500.0, 900.0, steps=2)

    assert ("resolve", "Canvas/ScrollView") in c.calls
    press = c.events()[0]
    assert press[1:] == ("Canvas/ScrollView", "press", 1, None, None)


def test_drag_xy_moves_in_steps_and_ends_at_the_target():
    c = FakeClient()
    make(c).ugui_drag_xy("Canvas/ScrollView", 0.0, 0.0, 100.0, 200.0, steps=4)

    moves = [e for e in c.events() if e[2] == "move"]
    assert len(moves) == 4
    assert moves[0][4:] == (25.0, 50.0)
    assert moves[-1][4:] == (100.0, 200.0)   # **終点にちょうど着く**


def test_drag_xy_releases_at_the_end():
    c = FakeClient()
    make(c).ugui_drag_xy("Canvas/ScrollView", 0.0, 0.0, 10.0, 10.0, steps=1)

    last = c.events()[-1]
    assert last[2] == "release" and last[3] == 1


def test_drag_xy_uses_the_given_pointer_id():
    """複数の指を同時に置く用途（押しながら別の操作）。"""
    c = FakeClient()
    make(c).ugui_drag_xy("Canvas/ScrollView", 0.0, 0.0, 10.0, 10.0, steps=1, pointer_id=7)

    assert {e[3] for e in c.events()} == {7}


def test_drag_xy_holds_at_the_end_before_releasing(monkeypatch):
    """hold > 0 で終点保持（仮想スティックを倒し続ける）。**離す前に待つ**ことを見る。"""
    c = FakeClient()
    slept: list[float] = []
    monkeypatch.setattr("e2e_driver.gestures.time.sleep", lambda s: slept.append(s))
    make(c).ugui_drag_xy("Canvas/ScrollView", 0.0, 0.0, 10.0, 10.0, steps=1, hold=1.5)

    assert 1.5 in slept


def test_drag_xy_without_hold_does_not_wait():
    """対照: hold を渡さなければ保持しない。"""
    c = FakeClient()
    slept: list[float] = []
    g = make(c)
    import e2e_driver.gestures as mod
    orig = mod.time.sleep
    try:
        mod.time.sleep = lambda s: slept.append(s)
        g.ugui_drag_xy("Canvas/ScrollView", 0.0, 0.0, 10.0, 10.0, steps=1)
    finally:
        mod.time.sleep = orig

    assert all(s == 0.0 for s in slept)


def test_drag_xy_releases_before_raising_when_blocked():
    """**押下は成立しているので、掴んだままにしない。**

    ここを落とすと、以後のポインタが押されっぱなしで残り、
    次のテストが理由の分からない失敗をする。
    """
    c = FakeClient(press_hittable=False)
    with pytest.raises(BlockedError):
        make(c).ugui_drag_xy("Canvas/ScrollView", 12.0, 300.0, 12.0, 900.0, steps=2)

    events = c.events()
    assert events[-1][2] == "release"
    assert [e for e in events if e[2] == "move"] == []   # 動かす前に止まる


# ----------------------------------------------------------------- ugui_press

def test_press_with_xy_skips_center_hittest():
    c = FakeClient()
    make(c).ugui_press("Canvas/ScrollView", 3, x=12.0, y=300.0)

    assert [k for k, *_ in c.calls if k == "resolve"] == []
    assert c.events()[0][1:] == ("Canvas/ScrollView", "press", 3, 12.0, 300.0)


def test_press_without_xy_still_hittests_center():
    """対照: 従来の呼び方は挙動を変えない。"""
    c = FakeClient()
    make(c).ugui_press("Canvas/Button", 3)

    assert ("resolve", "Canvas/Button") in c.calls
    assert c.events()[0][1:] == ("Canvas/Button", "press", 3, None, None)


def test_press_blocked_at_the_given_point_raises():
    """座標を指定しても、**その座標で届かなければ止める**（黙って緑にしない）。"""
    c = FakeClient(press_hittable=False)
    with pytest.raises(BlockedError):
        make(c).ugui_press("Canvas/ScrollView", 1, x=12.0, y=300.0)

    assert c.events()[-1][2] == "release"
