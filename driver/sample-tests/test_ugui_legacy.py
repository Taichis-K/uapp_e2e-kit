"""unity-ugui-legacy（uGUI + レガシー Input のみ）のE2E。

このプロジェクトは **`activeInputHandler: 0`（Input Manager (Old) のみ）** で、
EventSystem も `StandaloneInputModule`。導入先で実際にある構成をそのまま置いてある。

この構成では:
- Touchscreen 注入（`pointer_*` / `tap`）は**誰にも読まれない**ので uGUI に届かない（負のテストで確認）
- キー / マウス / パッドの注入は **`INPUT_BACKEND_LEGACY` で明示エラー**になる（対照）
- 操作は **`ugui_event`（EventSystem/ExecuteEvents へ直接送出）** を使う ← 本命経路
- OS レベルの実タップ（`adb input tap`）は届く（レガシー Input は実入力を受ける）

**`ugui_event` が保証するのは uGUI のイベント経路より内側だけ**なので、
「実際に指で触れて届くか」は adb の実タップ側で確かめる（`ngui_*` と同じ分担）。
"""
import time

import pytest

from e2e_driver import BlockedError, BridgeError, adb


def _active(client, path):
    """存在すれば active を、見つからなければ None を返す（wait_until_visible と同じ根拠）。"""
    try:
        return client.resolve(path).get("active")
    except Exception:
        return None


def _all_nodes(dump):
    """dump のトップレベルは {"screen":…, "scene":…, "nodes": [...]} で**ノードではない**。
    そのまま再帰すると `name` が無い入れ物を掴んで KeyError になる（実際に踏んだ）。"""
    def walk(node):
        yield node
        for child in node.get("children", []):
            yield from walk(child)
    for root in dump.get("nodes", []):
        yield from walk(root)


@pytest.fixture(autouse=True)
def _clean_state(client, g):
    """**前のテストが残した状態を持ち越さない**（押しっぱなし・ダイアログ開きっぱなし）。

    これが無いと、1 件が途中で失敗しただけで後続が芋づるに落ちて
    「何が壊れているのか」が読めなくなる（実際にそうなった）。
    """
    client.input_reset()
    if _active(client, "Dialog") is True:
        g.ugui_tap("CloseButton")
        g.wait_until_gone("Dialog")
    yield


def test_scene_has_expected_nodes(client):
    nodes = list(_all_nodes(client.dump()))
    names = {n["name"] for n in nodes}
    for expected in ("StartButton", "ButtonA", "ButtonB", "LoadButton", "VolumeSlider"):
        assert expected in names, f"{expected} が dump に無い: {sorted(names)}"


def test_event_system_is_legacy_module(client):
    """構成の忠実性。**ここが崩れると、以下の検証は全部意味を失う**。

    `InputSystemUIInputModule` に替わっていれば `tap` が届いてしまい、
    「ugui_event が要る」という前提自体が成り立たなくなる（＝偽の緑）。
    """
    # **EventSystem は Canvas 配下ではない別ルート**なので、既定の dump（scope="ui"）には出ない。
    # 実物のコンポーネントを直接読む（resolve は全ルートを走査する）
    assert client.get("EventSystem", "StandaloneInputModule", "enabled") is True


# --------------------------------------------------------------- 負のテスト（構成の忠実性）

def test_touch_injection_is_refused_explicitly(client, g):
    """Touchscreen 注入は**黙って届かないのではなく、明示エラーで断られる**。

    このサンプルは com.unity.inputsystem を入れていないので、注入はそもそも成立しない。
    **重要なのは「黙って何も起きない」にしないこと** ―
    黙ると、呼び手はアプリのバグを疑って延々と調べることになる。

    （パッケージはあるが Active Input Handling が 0 の構成では、注入は成立するが
    誰も読まない＝**本当に黙って効かない**。その構成の忠実性は unity-ngui-legacy 側で見ている）
    """
    assert _active(client, "Dialog") is not True
    with pytest.raises(BridgeError) as e:
        g.tap("StartButton")
    assert e.value.code == "INPUT_SYSTEM_NOT_PRESENT", f"想定外のコード: {e.value.code}"
    time.sleep(0.5)
    assert _active(client, "Dialog") is not True, "断ったはずの注入が実際には届いている"


def test_device_injection_fails_with_explicit_error(client):
    """キー / マウス / パッドの注入は**黙って効かないのではなく明示エラー**になる。

    黙って 0 のままだと、呼び手はアプリのバグを疑って延々と調べることになる。
    「この構成では原理的に無理」と即座に分かることが、この構成での正しい挙動。

    **このサンプルは com.unity.inputsystem を入れていない**ので
    `INPUT_SYSTEM_NOT_PRESENT`（パッケージ不在）が返る。パッケージはあるが
    Active Input Handling が 0 の構成では `INPUT_BACKEND_LEGACY` になる ―
    **直し方が違うので区別する**（前者はパッケージ導入、後者は Player Settings）。
    """
    for call in (lambda: client.key_down("space"),
                 lambda: client.mouse_down("left"),
                 lambda: client.pad_button_down("south")):
        with pytest.raises(BridgeError) as e:
            call()
        assert e.value.code == "INPUT_SYSTEM_NOT_PRESENT", f"想定外のコード: {e.value.code}"

    # 的の側も動いていないこと（エラーだけ出て実は入っていた、を否定する）
    assert client.get("DemoRoot", "DirectInputReporter", "SpaceCount") == 0


def test_input_devices_reports_reason_instead_of_failing(client):
    """診断コマンドは落とさない。**例外になると「なぜ使えないか」を調べる手段まで失われる**。"""
    info = client.input_devices()
    assert info["available"] is False
    assert "com.unity.inputsystem" in info["reason"]


# --------------------------------------------------------------- 本命経路

def test_ugui_tap_opens_and_closes_dialog(client, g, journey):
    """この構成の本命: ugui_event（ExecuteEvents への直接送出）"""
    journey.capture("main", label="メイン画面")
    g = journey.wrap(g)

    assert _active(client, "Dialog") is not True
    g.ugui_tap("StartButton")
    g.wait_until_visible("Dialog")
    journey.capture("dialog", label="ダイアログ表示")

    g.ugui_tap("CloseButton")
    g.wait_until_gone("Dialog")


def test_ugui_press_release_reports_hold(client, g):
    """press / release が分かれて届く（押しっぱなしの状態が観測できる）。"""
    g.ugui_press("ButtonA")
    assert client.get("HoldStatus", "Text", "text") == "A: HELD"
    g.ugui_release()
    assert client.get("HoldStatus", "Text", "text") == "A: UP"


def test_multi_pointer_hold_and_tap(client, g):
    """**uGUI 経路のマルチタッチ**: A を押したまま B をタップして SubMenu が開く。

    レガシー Input には注入の API が無いので `Input.touchCount` 直読みのピンチは
    動かせないが、**uGUI のイベント経路を通るマルチタッチは pointerId を分ければ再現できる**
    （ExecuteEvents は入力バックエンドと無関係）。ここはその境界を固定するテスト。
    """
    g.ugui_press("ButtonA", pointer_id=1)
    assert client.get("HoldStatus", "Text", "text") == "A: HELD"

    # A を押したまま B をタップする（別の指＝別 pointerId）
    g.ugui_tap("ButtonB", pointer_id=2)
    g.wait_until_visible("SubMenu")

    # ここまで A は押されたまま（B の操作が A の状態を壊していない）
    assert client.get("HoldStatus", "Text", "text") == "A: HELD"
    g.ugui_release(pointer_id=1)
    assert client.get("HoldStatus", "Text", "text") == "A: UP"

    g.ugui_tap("ButtonB", pointer_id=2)
    g.wait_until_gone("SubMenu")


def test_ugui_tap_is_blocked_by_overlay(client, g):
    """遮蔽は BlockedError で止まる（送出側を変えてもヒットテストは同じ）。"""
    g.ugui_tap("LoadButton")
    g.wait_until_visible("Blocker")
    with pytest.raises(BlockedError):
        g.ugui_tap("StartButton")
    g.wait_until_hittable("StartButton", timeout=10.0)


def test_release_uses_current_hit_not_press_time_hit(client, g):
    """**離した時点のヒット対象で判定する**（押した時点の結果を使い回さない）。

    遷移でしか出ない欠陥の回帰（codex 指摘）。指 1 で StartButton を押したまま、
    指 2 で Blocker を出し、指 1 を離す ― press 時の raycast を使い回すと
    **遮蔽された StartButton にクリックが通ってダイアログが開く**。
    単発のタップ検証では絶対に出ない。
    """
    assert _active(client, "Dialog") is not True
    g.ugui_press("StartButton", pointer_id=1)
    g.ugui_tap("LoadButton", pointer_id=2)      # 2 秒の全画面 Blocker が出る
    g.wait_until_visible("Blocker")

    result = client.ugui_event(event="release", pointer_id=1)
    assert result["clicked"] is False, "遮蔽されているのにクリックが成立した"
    time.sleep(0.5)
    assert _active(client, "Dialog") is not True, "遮蔽された対象へクリックが通っている"
    g.wait_until_hittable("StartButton", timeout=10.0)


def test_ugui_drag_moves_slider(client, g):
    """ドラッグ経路（press → move → release）。**単発のクリックでは通らない道**。"""
    before = client.get("VolumeSlider", "Slider", "value")
    center = client.resolve("VolumeSlider")["center"]
    g.ugui_drag("VolumeSlider", center["x"] + 250, center["y"])
    after = client.get("VolumeSlider", "Slider", "value")
    assert after > before, f"ドラッグで Slider が動いていない: {before} -> {after}"


def test_input_reset_releases_ugui_pointer(client, g):
    """押しっぱなしのまま放置しても input_reset で復帰できる。

    解放されないと以後の press が全部 ALREADY_PRESSED で落ちる（タッチ側と同型の事故）。
    """
    g.ugui_press("ButtonA", pointer_id=1)
    g.ugui_press("ButtonB", pointer_id=2)   # 2 本掴んだ状態から復帰できること
    result = client.input_reset()
    assert result["releasedUgui"] == 2
    assert client.get("HoldStatus", "Text", "text") == "A: UP"
    g.ugui_press("ButtonA")  # 解放できていれば通る
    g.ugui_release()


# --------------------------------------------------------------- 実入力（OS レベル）

def test_real_tap_reaches_ugui(client, g):
    """**実入力は届く**（レガシー Input は実タップを受ける）。

    ugui_event が保証しない外側 ― 「本当に指で押せるか」はここで確かめる。
    """
    assert _active(client, "Dialog") is not True
    resolved = client.resolve("StartButton")
    screen = client.dump()["screen"]
    adb.input_tap_unity_coords(
        resolved["center"]["x"], resolved["center"]["y"], (screen["w"], screen["h"]))
    g.wait_until_visible("Dialog")
    g.ugui_tap("CloseButton")
    g.wait_until_gone("Dialog")


def test_ugui_press_at_a_given_point_uses_that_point(client, g):
    """`ugui_press` に座標を渡すと**その位置で押される**（issue #61）。

    uGUI の Slider は**押した位置で値が決まる**ので、押した座標がそのまま value に出る。

    **move を挟まないのがこのテストの要点。** 一度でも動かすと Slider は
    move 先の値になるので、**press の座標が効いたのか move が効いたのかを分けられない**
    （最初そう書いて、press の座標を無視する変異を入れても通ってしまった）。
    """
    resolved = client.resolve("VolumeSlider")
    cx, cy = resolved["center"]["x"], resolved["center"]["y"]
    width = resolved["rect"]["w"]

    g.ugui_press("VolumeSlider", 1, x=cx - width * 0.25, y=cy)
    g.ugui_release(pointer_id=1)
    at_left = client.get("VolumeSlider", "Slider", "value")

    g.ugui_press("VolumeSlider", 1, x=cx + width * 0.25, y=cy)
    g.ugui_release(pointer_id=1)
    at_right = client.get("VolumeSlider", "Slider", "value")

    assert at_left < at_right, (
        f"押す位置を変えても値が変わらない（座標が効いていない）: 左={at_left} 右={at_right}"
    )


def test_ugui_drag_xy_moves_from_the_given_point(client, g):
    """対照: **始点から終点へ動かす**ぶんは従来どおり効く（掴む位置を変えても壊れていない）。

    **ここで効いているのは終点座標だけ**で、**始点は検証できていない** ―
    press の直後に必ず move が入り、Slider は最終値しか見せないため
    （`x2 = x1` にしても move が同じ位置へ動かすので変わらない）。
    **始点は `test_gestures_unit.py` のモック単体が保証している**という**合成**で成り立つ:
    モックが「始点が press に載る」を、この E2E が「ブリッジが press の座標を尊重する」
    （直上の `test_ugui_press_at_a_given_point_uses_that_point`）を受け持つ。
    """
    resolved = client.resolve("VolumeSlider")
    cx, cy = resolved["center"]["x"], resolved["center"]["y"]
    width = resolved["rect"]["w"]

    left = cx - width * 0.4
    g.ugui_drag_xy("VolumeSlider", left, cy, cx + width * 0.4, cy, steps=8)
    after = client.get("VolumeSlider", "Slider", "value")

    g.ugui_drag_xy("VolumeSlider", cx + width * 0.4, cy, left, cy, steps=8)
    back = client.get("VolumeSlider", "Slider", "value")

    assert after > back, f"始点→終点の移動が効いていない: 右へ={after} 左へ={back}"
