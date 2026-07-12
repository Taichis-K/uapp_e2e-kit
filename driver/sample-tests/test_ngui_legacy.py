"""unity-ngui-legacy（NGUI + レガシーInput読み構成）のE2E。

FORCE_OLD_INPUT により NGUI は UnityEngine.Input を直読みする。この構成では:
- Touchscreen注入（pointer_*）は NGUI に届かない（負のテストで確認）
- 操作は ngui_event（UICamera.Notify）を使う
- OSレベルの実タップ（adb input tap）は届く（レガシーInputは実入力を受ける）
"""
import time

import pytest

from e2e_driver import BlockedError, adb


def test_ngui_detected(client):
    assert client.ping().get("ngui") is True


def test_ngui_dump_contains_widgets(client):
    dump = client.dump()
    nodes = list(_all_nodes(dump))
    assert any(n["name"] == "NguiButton" and n.get("ui") == "ngui" for n in nodes)


def test_input_injection_does_not_reach_legacy_ngui(client, g):
    """負のテスト: Touchscreen注入はレガシーInput読みのNGUIには届かない（構成の忠実性確認）"""
    before = client.get("NguiButton", "NguiClickCounter", "clickCount")
    g.tap("NguiButton")  # hittable検証は通る（レイキャストは入力と無関係）が、クリックは発火しないはず
    time.sleep(1.0)  # 「何も起きない」ことの確認のため待てる条件が無い（sleepの例外用途）
    after = client.get("NguiButton", "NguiClickCounter", "clickCount")
    assert after == before, \
        f"レガシー構成なのにTouchscreen注入が届いている: {before} -> {after}"


def test_ngui_event_works(client, g, journey):
    """レガシー構成の本命経路: ngui_event（UICamera.Notify）"""
    journey.capture("main", label="メイン画面")
    g = journey.wrap(g)
    before = client.get("NguiButton", "NguiClickCounter", "clickCount")
    g.ngui_tap("NguiButton")
    assert client.get("NguiButton", "NguiClickCounter", "clickCount") > before

    g.ngui_press("NguiButton")
    assert client.get("NguiButton", "NguiClickCounter", "pressed") is True
    g.ngui_release("NguiButton")
    assert client.get("NguiButton", "NguiClickCounter", "pressed") is False


def test_real_tap_via_adb_reaches_legacy_ngui(client, g):
    """OSレベルの実タップは全入力スタックを通るため、レガシーNGUIにも届く"""
    resolved = client.resolve("NguiButton")
    assert resolved["hittable"] is True
    screen = client.ping()["screen"]

    before = client.get("NguiButton", "NguiClickCounter", "clickCount")
    adb.input_tap_unity_coords(
        resolved["center"]["x"], resolved["center"]["y"], (screen["w"], screen["h"]))
    g.wait_until(lambda: client.get("NguiButton", "NguiClickCounter", "clickCount") > before,
                 timeout=5, message="adb実タップがレガシーNGUIに届かない")


def test_blocked_by_collider(client, g):
    resolved = client.resolve("NguiCoveredButton")
    assert resolved.get("hittable") is False
    assert "NguiBlocker" in resolved.get("blockedBy", "")

    with pytest.raises(BlockedError):
        g.ngui_tap("NguiCoveredButton")


def _all_nodes(dump):
    stack = list(dump["nodes"])
    while stack:
        node = stack.pop()
        yield node
        stack.extend(node.get("children", []))
