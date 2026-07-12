"""unity-ngui-nis（NGUI + New Input System 構成）のE2E。

実プロジェクト同等の配線（NGUI入力ラッパー → InputUnity互換スタブ → EnhancedTouch）を検証する:
- Touchscreen注入（pointer_*）がUICameraまで届いてOnClickが発火する
- ngui_event（フレームワークレベル送出）も併用できる
- NGUI自前レイキャストでの遮蔽検知
"""
import pytest

from e2e_driver import BlockedError


def test_ngui_detected(client):
    assert client.ping().get("ngui") is True, "NGUIがリフレクション検出されていない"


def test_ngui_dump_contains_widgets(client):
    dump = client.dump()
    nodes = list(_all_nodes(dump))
    assert any(n["name"] == "NguiButton" and n.get("ui") == "ngui" for n in nodes), \
        "NguiButton (ui=ngui) が dump に見つからない"
    assert any(n.get("text") == "NguiButton" for n in nodes), \
        "UILabel のテキストが抽出されていない"


def test_tap_via_input_injection_reaches_ngui(client, g, journey):
    """NIS構成の本命経路: Touchscreen注入 → 入力ラッパー(EnhancedTouch) → UICamera → OnClick"""
    journey.capture("main", label="メイン画面")
    g = journey.wrap(g)
    before = client.get("NguiButton", "NguiClickCounter", "clickCount")
    g.tap("NguiButton")
    g.wait_until(lambda: client.get("NguiButton", "NguiClickCounter", "clickCount") > before,
                 timeout=5, message="タッチ注入でNGUIのOnClickが発火しない")


def test_ngui_event_also_works(client, g):
    before = client.get("NguiButton", "NguiClickCounter", "clickCount")
    g.ngui_tap("NguiButton")
    assert client.get("NguiButton", "NguiClickCounter", "clickCount") > before

    g.ngui_press("NguiButton")
    assert client.get("NguiButton", "NguiClickCounter", "pressed") is True
    g.ngui_release("NguiButton")
    assert client.get("NguiButton", "NguiClickCounter", "pressed") is False


def test_blocked_by_collider(client, g):
    resolved = client.resolve("NguiCoveredButton")
    assert resolved.get("hittable") is False
    assert "NguiBlocker" in resolved.get("blockedBy", "")

    with pytest.raises(BlockedError):
        g.tap("NguiCoveredButton")
    with pytest.raises(BlockedError):
        g.ngui_tap("NguiCoveredButton")


def _all_nodes(dump):
    stack = list(dump["nodes"])
    while stack:
        node = stack.pop()
        yield node
        stack.extend(node.get("children", []))
