"""サンプルアプリのスモークE2E。

このファイルは「AIが書くE2Eテスト」のリファレンス実装を兼ねる:
- タップ前に hittable を検証（Gestures.tap が自動で行う）
- sleep ではなく wait_until_* で待つ
- マルチタッチテストでは logcat の例外もアサートする
- 画面の節目で journey.capture して画面地図を育てる（docs/07-viewer.md。
  記録先が無効なら no-op なのでテストは記録の有無を意識しない）
"""
import time

import pytest

from e2e_driver import BlockedError, BridgeClient, Gamepad, Keyboard, Mouse, adb


def test_ping_and_dump(client):
    info = client.ping()
    assert info["bridge"] == "1.0"

    dump = client.dump()
    names = _collect_names(dump["nodes"])
    for expected in ("StartButton", "ButtonA", "ButtonB", "LoadButton", "PinchTarget"):
        assert expected in names, f"{expected} がシーンにありません"


def test_resolve_full_path_from_dump(client):
    """dump が返す完全パスをそのまま resolve できること。

    resolve のルート探索が SceneManager.GetRootGameObjects 依存だと
    DontDestroyOnLoad 配下（実プロジェクトの常駐UIの定石）が NOT_FOUND になる。
    その修正（全ルート Transform 走査）の回帰テスト。
    """
    dump = client.dump()
    paths = _collect_button_paths(dump["nodes"])
    deep = [p for p in paths if "/" in p]
    assert deep, "階層パス付きノードが dump にありません"
    for path in deep[:5]:
        resolved = client.resolve(path)
        assert resolved["path"] == path


def test_tap_opens_and_closes_dialog(g, journey):
    journey.capture("main", label="メイン画面")
    g = journey.wrap(g)  # 以降の tap が操作ログ（カバレッジ）に残る
    g.tap("StartButton")
    g.wait_until_visible("Dialog")
    journey.capture("dialog", label="ダイアログ")  # 遷移 main→dialog が自動記録される
    g.tap("CloseButton")
    g.wait_until_gone("Dialog")
    journey.capture("main")


def test_fullscreen_blocker_blocks_and_releases(client, g):
    g.tap("LoadButton")
    g.wait_until_visible("Blocker")

    # ブロッカー表示中は StartButton に実タッチが届かない
    resolved = client.resolve("StartButton")
    assert resolved["hittable"] is False
    assert "Blocker" in resolved.get("blockedBy", "")

    # 遮蔽中のタップは診断付きで失敗する
    with pytest.raises(BlockedError) as exc_info:
        g.tap("StartButton")
    assert "Blocker" in exc_info.value.blocked_by

    # ブロッカー解除を待てばタップできる
    g.wait_until_hittable("StartButton", timeout=5)
    g.tap("StartButton")
    g.wait_until_visible("Dialog")
    g.tap("CloseButton")
    g.wait_until_gone("Dialog")


def test_hold_a_tap_b_then_release(client, g):
    """A を押し込んだまま B をタップして UI が開き、その後 A を離しても破綻しないこと。"""
    adb.clear_logcat()

    g.press("ButtonA", pointer_id=2)
    assert client.get("ButtonA", "HoldStateReporter", "isHeld") is True

    g.tap("ButtonB", pointer_id=3)  # A を保持したまま別ポインタでタップ
    g.wait_until_visible("SubMenu")

    g.release(2)  # UI が変化した後に A を離す
    assert client.get("ButtonA", "HoldStateReporter", "isHeld") is False

    # UI 状態に現れない破綻（例外）も検出する
    exceptions = adb.unity_exceptions()
    assert not exceptions, f"Unity 例外が発生: {exceptions[:5]}"

    g.tap("ButtonB")  # 後片付け: SubMenu を閉じる
    g.wait_until_gone("SubMenu")


def test_second_client_not_blocked(client):
    """セッション接続を開いたまま、別クライアントも応答を得られること。

    ブリッジは接続ごとに独立スレッドで応対する（直列応対だと、不正終了した
    クライアントの残留接続が以降の接続を永久に塞ぐ）。その設計の回帰テスト。
    """
    c2 = BridgeClient(port=client.port, timeout=10.0).connect(retries=1)  # 1本目と同じ接続先へ
    try:
        assert c2.ping()["bridge"] == "1.0"
    finally:
        c2.close()


def test_pinch_zoom(client, g):
    """開始時のスケール（上限クランプ残留等）に依存しないよう、
    先にピンチインで拡大余地を作ってからピンチアウトを検証する。"""
    # sleep は「ピンチ終了後の物理値の安定待ち」の例外用途。目標値が事前に分からず
    # wait_until で待てる条件が無い（規約: 待てる条件があるなら wait_until_* を使う）
    g.pinch("PinchTarget", dist_from=400, dist_to=100, duration=0.5)  # 縮小
    time.sleep(0.2)
    scale_small = client.get("PinchTarget", "RectTransform", "localScale")["x"]

    g.pinch("PinchTarget", dist_from=100, dist_to=400, duration=0.5)  # 拡大
    time.sleep(0.2)
    scale_large = client.get("PinchTarget", "RectTransform", "localScale")["x"]

    assert scale_large > scale_small * 1.5, \
        f"ピンチで拡大されていません: {scale_small} -> {scale_large}"


def _collect_names(nodes):
    names = set()
    stack = list(nodes)
    while stack:
        node = stack.pop()
        names.add(node["name"])
        stack.extend(node.get("children", []))
    return names


def _collect_button_paths(nodes):
    """probe が付いた（hittable 判定のある）ノードの完全パスを集める。"""
    paths = []
    stack = list(nodes)
    while stack:
        node = stack.pop()
        if "hittable" in node and node.get("path"):
            paths.append(node["path"])
        stack.extend(node.get("children", []))
    return paths


def test_direct_input_reaches_the_app(client):
    """**UI を経由しない入力**（キー / マウス / パッド）がアプリに届くこと。

    tap(path) は uGUI の当たり判定を通る道なので、キー入力やパッド操作を見ているコードは
    検証できない。ここは Input System のデバイスへ直接注入する経路の回帰テスト。
    注入先は専用の仮想デバイス（実機が刺さっていても、その報告に上書きされない）。
    """
    reporter, component = "DemoRoot/DirectInput", "DirectInputReporter"
    keyboard, mouse, pad = Keyboard(client), Mouse(client), Gamepad(client)
    client.input_reset()

    before = client.get(reporter, component, "SpaceCount")
    keyboard.press("space")
    assert client.get(reporter, component, "SpaceCount") == before + 1

    keyboard.down("w")
    assert client.get(reporter, component, "WHeld") is True      # 押しっぱなしが保たれる
    keyboard.up("w")
    assert client.get(reporter, component, "WHeld") is False

    before = client.get(reporter, component, "LeftClickCount")
    mouse.click(540, 1200)
    assert client.get(reporter, component, "LeftClickCount") == before + 1
    assert client.get(reporter, component, "LastClickPos") == {"x": 540.0, "y": 1200.0}

    before = client.get(reporter, component, "PadSouthCount")
    pad.press("buttonSouth")                                     # 列挙名 South でも同じ
    assert client.get(reporter, component, "PadSouthCount") == before + 1
    pad.stick("left", 0.0, 1.0)
    assert client.get(reporter, component, "LeftStick") == {"x": 0.0, "y": 1.0}
    client.input_reset()
    assert client.get(reporter, component, "LeftStick") == {"x": 0.0, "y": 0.0}


def test_input_devices_reports_real_hardware(client):
    """実機の入力デバイスが刺さっているかを見えるようにすること。

    エディタ実行の PC には本物のキーボード・パッドが同時に居る。人が触れば current を奪われ、
    テストが揺れる。原因不明の不安定さにしないため、一覧と実機の本数を返す。
    """
    info = client.input_devices()
    assert isinstance(info["devices"], list)
    for key in ("realGamepads", "realKeyboards", "realMice"):
        assert isinstance(info[key], int)
    # **仮想デバイスは遅延生成**（初回注入時）。未生成の種別も created:false で並ぶこと
    # （並ばないと「実機に注入している」と誤読され、devices を名前で引いて KeyError になる）
    virtuals = {v["kind"]: v for v in info["virtualDevices"]}
    assert set(virtuals) == {"keyboard", "mouse", "gamepad"}
    assert virtuals["keyboard"]["name"] == "E2EVirtualKeyboard"
    assert virtuals["mouse"]["name"] == "E2EVirtualMouse"
    assert virtuals["gamepad"]["name"] == "E2EVirtualGamepad"
    for entry in virtuals.values():
        assert isinstance(entry["created"], bool)
    # 注入したら、その仮想デバイスが一覧に出て created も真になること
    Keyboard(client).press("space")
    after = client.input_devices()
    assert "E2EVirtualKeyboard" in [d["name"] for d in after["devices"]]
    assert {v["kind"]: v["created"] for v in after["virtualDevices"]}["keyboard"] is True
