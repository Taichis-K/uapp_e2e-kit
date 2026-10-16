# ジャーニー記録（e2e_driver.journey）のロジック単体テスト。デバイス・アプリ不要。
# ボタン抽出 / 遷移の自動記録と重複排除 / 追記マージ / no-op モード / HTMLエクスポートを検証する。
import json

import pytest

from e2e_driver import journey as jmod
from e2e_driver.journey import JourneyRecorder, export_html


def _btn(path, hittable=True, **extra):
    node = {"name": path.split("/")[-1], "path": path, "active": True,
            "components": ["RectTransform", "Button"],
            "rect": {"x": 0, "y": 0, "w": 100, "h": 50},
            "center": {"x": 50, "y": 25}, "hittable": hittable, "children": []}
    node.update(extra)
    return node


class FakeClient:
    """2画面（title / home）を持つ最小のブリッジモデル。"""

    def __init__(self):
        self.screen = "title"
        self.screens = {
            "title": [_btn("Canvas/StartButton"), _btn("Canvas/Locked", hittable=False, blockedBy="Canvas/Mask"),
                      {"name": "Logo", "path": "Canvas/Logo", "active": True, "components": ["Image"], "children": []}],
            "home": [_btn("Canvas/BackButton")],
        }

    def ping(self):
        return {"bridge": "1.0", "app": "com.example.fake", "unity": "6000.0.0f1",
                "screen": {"w": 1080, "h": 2400}}

    def dump(self, scope="ui", probe="selectable", path=None):
        return {"screen": {"w": 1080, "h": 2400}, "scene": self.screen,
                "nodes": [{"name": "Canvas", "path": "Canvas", "active": True,
                           "components": ["Canvas"], "children": self.screens[self.screen]}]}


class FakeGestures:
    def __init__(self, client):
        self.client = client

    def tap(self, path, pointer_id=None):
        self.client.screen = {"Canvas/StartButton": "home", "Canvas/BackButton": "title"}.get(path, self.client.screen)


@pytest.fixture()
def no_screencap(monkeypatch):
    """adb 不要化: スクリーンショットをダミーPNGバイトで代替する。"""
    def fake(local_path):
        from pathlib import Path
        p = Path(local_path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"\x89PNG-fake")
        return p
    monkeypatch.setattr(jmod.adb, "screencap", fake)


def test_record_merge_and_transitions(tmp_path, no_screencap):
    client = FakeClient()
    rec = JourneyRecorder(client, tmp_path)
    g = rec.wrap(FakeGestures(client))
    rec.current_test = "t::flow"
    rec.capture("title", label="タイトル")
    g.tap("Canvas/StartButton")
    rec.capture("home")
    g.tap("Canvas/BackButton")
    rec.capture("title")
    rec.record_test("t::flow", "passed", 1.23)

    # 2回目の実行（別レコーダー）で追記マージされること
    client.screen = "title"
    rec2 = JourneyRecorder(client, tmp_path)
    g2 = rec2.wrap(FakeGestures(client))
    rec2.current_test = "t::flow2"
    rec2.capture("title")
    g2.tap("Canvas/StartButton")
    rec2.capture("home")
    rec2.record_test("t::flow2", "failed", 4.56)

    data = json.loads((tmp_path / "journey.json").read_text(encoding="utf-8"))
    assert data["format"] == jmod.FORMAT
    title = next(s for s in data["screens"] if s["id"] == "title")
    assert title["label"] == "タイトル", "label なしの再 capture で label が維持されること"
    names = [b["name"] for b in title["buttons"]]
    assert names == ["StartButton", "Locked"], "hittable判定が付いたノードのみボタン扱い"
    assert title["buttons"][1]["blockedBy"] == "Canvas/Mask"
    assert title["screenshot"] == "screens/title.png"
    assert (tmp_path / "screens" / "title.png").exists()
    js = (tmp_path / "journey.js").read_text(encoding="utf-8")
    assert js.startswith("window.JOURNEY_DATA = "), "viewer直接開き用の journey.js も出力されること"
    assert (tmp_path / "viewer.html").exists(), "ビューアー本体が journey ディレクトリに同梱されること"

    trans = [(t["from"], t["to"], t["via"]) for t in data["transitions"]]
    assert ("title", "home", "Canvas/StartButton") in trans
    assert ("home", "title", "Canvas/BackButton") in trans
    assert len(trans) == 2, "同一遷移（2回目の title→home）が重複しないこと"

    tests = {t["name"]: t for t in data["tests"]}
    assert tests["t::flow"]["outcome"] == "passed"
    assert [a["path"] for a in tests["t::flow"]["actions"]] == ["Canvas/StartButton", "Canvas/BackButton"]
    assert tests["t::flow"]["actions"][1]["screen"] == "home"
    assert tests["t::flow2"]["outcome"] == "failed"


def test_cross_test_auto_transition_suppressed(tmp_path, no_screencap):
    """タップなしの画面差し替えがテストをまたいだ場合、偽遷移を記録しないこと。"""
    client = FakeClient()
    rec = JourneyRecorder(client, tmp_path)
    rec.current_test = "t::a"
    rec.capture("title")
    client.screen = "home"  # タップを介さず状態が変わった
    rec.current_test = "t::b"
    rec.capture("home")
    data = json.loads((tmp_path / "journey.json").read_text(encoding="utf-8"))
    assert data["transitions"] == []


def test_history_regression_and_cumulative_actions(tmp_path, no_screencap):
    """結果履歴の累積・回帰フラグ・操作ログの累積マージを検証する。"""
    client = FakeClient()
    rec = JourneyRecorder(client, tmp_path)
    g = rec.wrap(FakeGestures(client))
    rec.current_test = "t::x"
    rec.capture("title")
    g.tap("Canvas/StartButton")
    rec.record_test("t::x", "passed", 1.0)

    # 2回目: 別経路で操作せず失敗 → 回帰。過去の操作（カバレッジ）は失われない
    rec2 = JourneyRecorder(client, tmp_path)
    rec2.current_test = "t::x"
    rec2.record_test("t::x", "failed", 2.0)
    data = json.loads((tmp_path / "journey.json").read_text(encoding="utf-8"))
    t = data["tests"][0]
    assert t["outcome"] == "failed" and t["regressed"] is True
    assert [h["outcome"] for h in t["history"]] == ["passed", "failed"]
    assert [a["path"] for a in t["actions"]] == ["Canvas/StartButton"], "操作ログは累積されること"

    # 3回目: 復帰 → 回帰フラグは下りる。履歴は3件
    rec3 = JourneyRecorder(client, tmp_path)
    rec3.current_test = "t::x"
    rec3.record_test("t::x", "passed", 1.5)
    data = json.loads((tmp_path / "journey.json").read_text(encoding="utf-8"))
    t = data["tests"][0]
    assert t["regressed"] is False
    assert [h["outcome"] for h in t["history"]] == ["passed", "failed", "passed"]


def test_match_screen():
    """探索モードの遷移先照合（ボタン構成のJaccard類似度）。"""
    from e2e_driver.journey import _match_screen
    screens = {
        "a": {"buttons": [{"path": f"Canvas/B{i}"} for i in range(10)]},
        "b": {"buttons": [{"path": f"Win/C{i}"} for i in range(5)]},
    }
    assert _match_screen(screens, {f"Canvas/B{i}" for i in range(10)}) == "a"
    # 1ボタン増（10/11 ≈ 0.91 ≥ 0.9）は同一画面、2ボタン欠け＋1増（8/11 ≈ 0.73）は別画面
    assert _match_screen(screens, {f"Canvas/B{i}" for i in range(10)} | {"Canvas/New"}) == "a"
    assert _match_screen(screens, {f"Canvas/B{i}" for i in range(8)} | {"Canvas/New"}) is None
    assert _match_screen(screens, {"Totally/Different"}) is None


def test_disabled_recorder_is_noop(tmp_path):
    rec = JourneyRecorder(FakeClient(), None, enabled=False)
    gestures = FakeGestures(FakeClient())
    assert rec.capture("x") is None
    assert rec.save() is None
    assert rec.wrap(gestures) is gestures, "無効時は素通しで委譲すること"


def test_deploy_viewer_backs_up_local_changes(tmp_path, no_screencap):
    """journey同梱の viewer.html が独自改修されていた場合、退避してから更新すること。"""
    client = FakeClient()
    rec = JourneyRecorder(client, tmp_path)
    rec.capture("title")
    viewer = tmp_path / "viewer.html"
    viewer.write_text("<!-- 導入先AIによる独自改修 -->", encoding="utf-8")
    rec.capture("title")  # save() が再配置する
    backups = list(tmp_path.glob("viewer-backup-*.html"))
    assert len(backups) == 1, "改修されたコピーが退避されること"
    assert backups[0].read_text(encoding="utf-8") == "<!-- 導入先AIによる独自改修 -->"
    assert viewer.read_bytes() != b"", "本体は最新テンプレートに更新されること"
    rec.capture("title")  # 同一内容なら再退避しない
    assert len(list(tmp_path.glob("viewer-backup-*.html"))) == 1


def test_export_html_embeds_data(tmp_path, no_screencap):
    client = FakeClient()
    rec = JourneyRecorder(client, tmp_path)
    rec.capture("title")
    out = export_html(tmp_path)
    html = out.read_text(encoding="utf-8")
    assert out.name == "report.html"
    assert '"format": "uapp-e2e-journey/1"'.replace(" ", "") in html.replace(" ", "")
    assert "data:image/png;base64," in html, "スクリーンショットが data URI で内蔵されること"
    assert ">null</script>" not in html, "データスロットが置換されていること"


def test_find_config_start_layouts(tmp_path):
    """serve のポート解決起点: 導入先（config が祖先）と開発リポジトリ（config が兄弟）の両対応。"""
    from e2e_driver.journey import _find_config_start
    # 導入先レイアウト: <プロジェクト>/uapp_e2e/Builds/journey → 祖先に config があるのでそのまま
    kit = tmp_path / "proj" / "uapp_e2e"
    kit_journey = kit / "Builds" / "journey"
    kit_journey.mkdir(parents=True)
    (kit / "e2e-config.json").write_text("{}", encoding="utf-8")
    assert _find_config_start(kit_journey) == kit_journey
    # 開発リポジトリレイアウト: Builds/journey/<サンプル名> と <サンプル名>/e2e-config.json が兄弟
    root = tmp_path / "dev"
    dev_journey = root / "Builds" / "journey" / "unity-x"
    dev_journey.mkdir(parents=True)
    sample = root / "unity-x"
    sample.mkdir()
    (sample / "e2e-config.json").write_text('{"uiType": "ngui-legacy"}', encoding="utf-8")
    assert _find_config_start(dev_journey) == sample
    # serve はこの起点から uiType も解決する（ポートだけ兄弟解決して uiType が None になる齟齬を防ぐ）
    from e2e_driver.journey import _find_ui_type
    assert _find_ui_type(_find_config_start(dev_journey)) == "ngui-legacy"
    # どこにも無ければ journey ディレクトリのまま（resolve_port が既定値へフォールバック）
    lone = tmp_path / "lone" / "journey"
    lone.mkdir(parents=True)
    assert _find_config_start(lone) == lone


# --- iOS シミュレータのスクリーンショット経路（simctl） -----------------------


def test_ios_screenshot_unavailable_without_udid(monkeypatch):
    """UAPP_E2E_IOS=1 でも UDID が無ければ撮らない（booted へのフォールバックはしない。

    複数シミュレータ起動時に別の個体の画面を「撮れた」と扱わないための約束）。
    """
    from e2e_driver import ios_screenshot

    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    monkeypatch.delenv("UAPP_E2E_IOS_UDID", raising=False)
    monkeypatch.setattr(ios_screenshot, "_xcrun", lambda: "/usr/bin/xcrun")
    assert ios_screenshot.available() is False


def test_ios_screenshot_capture_checks_output(monkeypatch, tmp_path):
    """終了コード 0 でもファイルが出来ていなければ失敗として扱う（壊れた画像リンクの防止）。"""
    from e2e_driver import ios_screenshot

    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    monkeypatch.setenv("UAPP_E2E_IOS_UDID", "0000-UDID")
    monkeypatch.setattr(ios_screenshot, "_xcrun", lambda: "/usr/bin/xcrun")

    calls = {}

    class _Result:
        returncode = 0

    def fake_run(cmd, **kwargs):
        calls["cmd"] = cmd
        if calls.get("write"):
            from pathlib import Path
            Path(cmd[-1]).write_bytes(b"\x89PNG-fake")
        return _Result()

    monkeypatch.setattr(ios_screenshot.subprocess, "run", fake_run)

    out = tmp_path / "s" / "shot.png"
    assert ios_screenshot.capture(out) is False        # exit 0 でもファイル無し → 失敗
    assert calls["cmd"][:4] == ["/usr/bin/xcrun", "simctl", "io", "0000-UDID"]

    calls["write"] = True
    assert ios_screenshot.capture(out) is True         # ファイルが出来ていれば成功

    # **再実行**: 前回の画像が残っている状態で「exit 0・何も書かない」→ 古い画像で
    # 成功と誤判定しないこと（撮影前に既存ファイルを消す）
    assert out.exists()
    calls["write"] = False
    assert ios_screenshot.capture(out) is False


# --- iOS 実機の OS 層キャプチャ（idevicescreenshot） ---------------------------


def test_ios_device_screenshot_requires_udid(monkeypatch):
    """UDID が無ければ撮らない（複数台つながっている環境で別端末を撮らない）。"""
    from e2e_driver import ios_device_screenshot

    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    monkeypatch.delenv("UAPP_E2E_IOS_DEVICE_UDID", raising=False)
    monkeypatch.setattr(ios_device_screenshot, "_tool", lambda: "/usr/bin/idevicescreenshot")
    assert ios_device_screenshot.available() is False


def test_ios_device_screenshot_converts_tiff(monkeypatch, tmp_path):
    """端末が TIFF を返しても PNG で保存する（拡張子を信じず先頭バイトで判定する）。"""
    from e2e_driver import ios_device_screenshot

    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    monkeypatch.setenv("UAPP_E2E_IOS_DEVICE_UDID", "0000-UDID")
    monkeypatch.setattr(ios_device_screenshot, "_tool", lambda: "/usr/bin/idevicescreenshot")
    monkeypatch.setattr(ios_device_screenshot.shutil, "which",
                        lambda name: "/usr/bin/sips" if name == "sips" else None)

    class _Ok:
        returncode = 0

    def fake_run(cmd, **kwargs):
        from pathlib import Path
        if cmd[0].endswith("idevicescreenshot"):
            Path(cmd[-1] + ".tiff").write_bytes(b"MM\x00*rest")   # TIFF を返す端末
        else:  # sips 変換
            Path(cmd[cmd.index("--out") + 1]).write_bytes(b"\x89PNG\r\n\x1a\nconverted")
        return _Ok()

    monkeypatch.setattr(ios_device_screenshot.subprocess, "run", fake_run)
    out = tmp_path / "shots" / "screen.png"
    assert ios_device_screenshot.capture(out) is True
    assert out.read_bytes().startswith(b"\x89PNG")


def test_ios_device_screenshot_fails_when_tool_errors(monkeypatch, tmp_path):
    """iOS 17 以降の Invalid service 等は静かに False（呼び出し側が次の手段へ落ちる）。"""
    from e2e_driver import ios_device_screenshot

    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    monkeypatch.setenv("UAPP_E2E_IOS_DEVICE_UDID", "0000-UDID")
    monkeypatch.setattr(ios_device_screenshot, "_tool", lambda: "/usr/bin/idevicescreenshot")

    class _Ng:
        returncode = 1

    monkeypatch.setattr(ios_device_screenshot.subprocess, "run", lambda *a, **k: _Ng())
    assert ios_device_screenshot.capture(tmp_path / "s.png") is False


# --- OS レイヤーエージェント（XCUITest）のクライアント ------------------------


def test_os_agent_available_requires_declaration(monkeypatch):
    """宣言（URL）が無ければこの経路は使わない（ブリッジのガードと同じ約束）。"""
    from e2e_driver import os_agent

    monkeypatch.delenv("UAPP_E2E_OS_AGENT_URL", raising=False)
    assert os_agent.available() is False
    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    assert os_agent.available() is True


def test_os_agent_status_rejects_foreign_server(monkeypatch):
    """同じポートを別のサーバーが握っていたら止める（黙って別物を操作しない）。"""
    import json as _json

    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    # **トークンの宣言は外してから確かめる**（このテストの対象は「相手が誰か」の判定）。
    # 残したままだと認証検査が先に働き、`run-ios-e2e.ps1 -OsAgent` から回したときだけ落ちる
    # — 認証側は test_os_agent_status_requires_authenticated_when_token_set が別に見ている
    monkeypatch.delenv("UAPP_E2E_OS_AGENT_TOKEN", raising=False)
    monkeypatch.setattr(os_agent, "_request",
                        lambda *a, **k: (_json.dumps({"agent": "something-else/9"}).encode(), "application/json"))
    with pytest.raises(os_agent.OsAgentError, match="OS エージェントではありません"):
        os_agent.status()

    monkeypatch.setattr(os_agent, "_request",
                        lambda *a, **k: (_json.dumps({"agent": "uapp-os-agent/1.0"}).encode(), "application/json"))
    assert os_agent.status()["agent"] == "uapp-os-agent/1.0"


def test_os_agent_status_requires_authenticated_when_token_set(monkeypatch):
    """トークンを使う設定なら、認証済みの応答でなければ止める。

    並行実行や古い USB トンネルの残骸（トークン無しで動くエージェント）へ繋いだまま
    **別個体を操作して緑になる**のを防ぐ。
    """
    import json as _json

    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    monkeypatch.setenv("UAPP_E2E_OS_AGENT_TOKEN", "secret")
    monkeypatch.setattr(os_agent, "_request", lambda *a, **k: (
        _json.dumps({"agent": "uapp-os-agent/1.0", "authenticated": False}).encode(), "application/json"))
    with pytest.raises(os_agent.OsAgentError, match="認証されていません"):
        os_agent.status()

    monkeypatch.setattr(os_agent, "_request", lambda *a, **k: (
        _json.dumps({"agent": "uapp-os-agent/1.0", "authenticated": True}).encode(), "application/json"))
    assert os_agent.status()["authenticated"] is True


def test_os_agent_type_requires_bundle_id(monkeypatch):
    """入力は対象アプリを明示させる（フォーカスは呼び出した要素の子孫に要る＝Apple の契約）。"""
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    sent = {}
    monkeypatch.setattr(os_agent, "_post", lambda path, payload, **k: sent.update({path: payload}) or {})
    os_agent.type_text("hello", bundle_id="com.example.app")
    assert sent["/type"] == {"text": "hello", "bundleId": "com.example.app"}


def test_os_agent_tap_unity_converts_coordinates(monkeypatch):
    """Unity 座標（左下原点・ピクセル）→ 正規化座標（左上原点）の変換。

    ここを間違えると**上下反転した場所を叩く**ので、変換だけは単体で押さえる。
    """
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    sent = {}
    monkeypatch.setattr(os_agent, "_post", lambda path, payload, **k: sent.update({path: payload}) or {})

    os_agent.tap_unity(288, 2124, (1179, 2556))     # 画面上部の左寄り
    assert sent["/tap"]["x"] == pytest.approx(288 / 1179, abs=1e-6)
    assert sent["/tap"]["y"] == pytest.approx(1 - 2124 / 2556, abs=1e-6)

    with pytest.raises(os_agent.OsAgentError, match="画面サイズが不正"):
        os_agent.tap_unity(1, 1, (0, 0))


def _os_agent_with_mocks(monkeypatch, *, features, base_echo=True):
    """bundle_id のテスト用。`_post` の送信を記録し、`/status` の features と応答の base を差し替える。"""
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    monkeypatch.setattr(os_agent, "_BUNDLE_ID_SUPPORTED", set())
    calls = {"post": [], "status": 0}

    def fake_post(path, payload, **k):
        calls["post"].append((path, payload))
        if "bundleId" in payload and base_echo is True:
            return {"ok": True, "base": payload["bundleId"]}
        if base_echo is True:
            return {"ok": True, "base": "springboard"}
        return base_echo  # 呼び手が指定した応答（古いエージェント・不一致を模す）

    def fake_status(**k):
        calls["status"] += 1
        return {"agent": "uapp-os-agent/1.0", "authenticated": True, "features": features}

    monkeypatch.setattr(os_agent, "_post", fake_post)
    monkeypatch.setattr(os_agent, "status", fake_status)
    return os_agent, calls


def test_os_agent_bundle_id_omitted_sends_same_json_as_before(monkeypatch):
    """**既定（bundle_id なし）は送る JSON が従来と同一**で、/status も呼ばない（後方互換）。"""
    os_agent, calls = _os_agent_with_mocks(monkeypatch, features=[])
    os_agent.tap(0.25, 0.75)
    os_agent.tap_unity(100, 200, (1000, 2000))
    os_agent.swipe(0.1, 0.2, 0.3, 0.4, duration=0.5)
    os_agent.swipe_unity(0, 0, 500, 1000, (1000, 2000), duration=0.3)
    assert calls["post"] == [
        ("/tap", {"x": 0.25, "y": 0.75}),
        ("/tap", {"x": 0.1, "y": pytest.approx(0.9)}),
        ("/swipe", {"x1": 0.1, "y1": 0.2, "x2": 0.3, "y2": 0.4, "duration": 0.5}),
        ("/swipe", {"x1": 0.0, "y1": 1.0, "x2": 0.5, "y2": pytest.approx(0.5), "duration": 0.3}),
    ]
    assert calls["status"] == 0
    assert all("bundleId" not in p for _, p in calls["post"])


def test_os_agent_bundle_id_is_sent_by_all_four_functions(monkeypatch):
    """bundle_id を渡すと 4 関数とも bundleId を送る（swipe_unity だけ漏れる、を防ぐ）。"""
    os_agent, calls = _os_agent_with_mocks(monkeypatch, features=["bundleId"])
    app = "com.example.app"
    os_agent.tap(0.5, 0.5, bundle_id=app)
    os_agent.tap_unity(100, 200, (2000, 1000), bundle_id=app)      # 横長の screen（横画面のアプリ）
    os_agent.swipe(0.1, 0.2, 0.3, 0.4, bundle_id=app)
    os_agent.swipe_unity(0, 0, 1000, 500, (2000, 1000), bundle_id=app)
    assert [p["bundleId"] for _, p in calls["post"]] == [app] * 4
    # 換算は bundle_id の有無で変わらない（横長の screen で正規化されるだけ）
    assert calls["post"][1][1]["x"] == pytest.approx(100 / 2000)
    assert calls["post"][1][1]["y"] == pytest.approx(1 - 200 / 1000)
    # /status での対応確認は URL ごとに 1 回だけ
    assert calls["status"] == 1


def test_os_agent_bundle_id_unsupported_agent_does_not_tap(monkeypatch):
    """**古いエージェント（features に bundleId が無い）には押さずに止める**。

    押してから応答で止めると、SpringBoard 基準の誤った位置をもう押し終えている。
    """
    os_agent, calls = _os_agent_with_mocks(monkeypatch, features=[])
    with pytest.raises(os_agent.OsAgentError, match="対応していません"):
        os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    with pytest.raises(os_agent.OsAgentError, match="対応していません"):
        os_agent.swipe_unity(0, 0, 10, 10, (100, 100), bundle_id="com.example.app")
    assert calls["post"] == []          # 1 回も押していない


def test_os_agent_bundle_id_empty_is_rejected_without_tapping(monkeypatch):
    """空文字を「省略」扱いにしない（設定漏れで黙って SpringBoard 基準に落ちるため）。"""
    os_agent, calls = _os_agent_with_mocks(monkeypatch, features=["bundleId"])
    with pytest.raises(os_agent.OsAgentError, match="空か文字列ではありません"):
        os_agent.tap(0.5, 0.5, bundle_id="")
    assert calls["post"] == [] and calls["status"] == 0


@pytest.mark.parametrize("response", [
    {"ok": True},                                   # base が無い（古い版が入れ替わった）
    {"ok": True, "base": "springboard"},            # SpringBoard 基準で押された
    {"ok": True, "base": "COM.EXAMPLE.APP"},        # 大小文字だけ違う（エコーなので区別する）
])
def test_os_agent_bundle_id_base_mismatch_raises(monkeypatch, response):
    """応答の base が送った値と完全一致しなければ止める（二重の安全）。tap と swipe の両方で見る。"""
    os_agent, _ = _os_agent_with_mocks(monkeypatch, features=["bundleId"], base_echo=response)
    with pytest.raises(os_agent.OsAgentError, match="base が送った bundle_id と一致しません"):
        os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    with pytest.raises(os_agent.OsAgentError, match="base が送った bundle_id と一致しません"):
        os_agent.swipe(0.1, 0.1, 0.2, 0.2, bundle_id="com.example.app")


def test_os_agent_bundle_id_support_is_checked_per_url(monkeypatch):
    """対応の確認は URL ごと（プロセス全体で 1 回にすると、別のエージェントへ繋ぎ替えたときに確かめない）。"""
    os_agent, calls = _os_agent_with_mocks(monkeypatch, features=["bundleId"])
    os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    assert calls["status"] == 1
    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8201")
    os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    assert calls["status"] == 2


def test_os_agent_bundle_id_support_is_rechecked_when_token_changes(monkeypatch):
    """同じ URL でもトークンが替われば別の起動なので確かめ直す（URL だけで覚えると、
    繋ぎ替えた個体の版も認証も確かめずに押してしまう）。"""
    os_agent, calls = _os_agent_with_mocks(monkeypatch, features=["bundleId"])
    monkeypatch.setenv("UAPP_E2E_OS_AGENT_TOKEN", "token-a")
    os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    assert calls["status"] == 1
    monkeypatch.setenv("UAPP_E2E_OS_AGENT_TOKEN", "token-b")
    os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    assert calls["status"] == 2


def test_os_agent_bundle_id_support_is_forgotten_after_base_mismatch(monkeypatch):
    """base が一致しなかったら、覚えていた「対応している」を捨てて次に確かめ直す。"""
    os_agent, calls = _os_agent_with_mocks(monkeypatch, features=["bundleId"], base_echo={"ok": True})
    with pytest.raises(os_agent.OsAgentError, match="base が送った bundle_id と一致しません"):
        os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    assert calls["status"] == 1
    with pytest.raises(os_agent.OsAgentError, match="base が送った bundle_id と一致しません"):
        os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    assert calls["status"] == 2          # 捨てていなければ 1 のまま


@pytest.mark.parametrize("bad", [123, b"com.example.app"])
def test_os_agent_bundle_id_non_string_is_rejected_without_tapping(monkeypatch, bad):
    """文字列でない bundle_id は送らずに止める。"""
    os_agent, calls = _os_agent_with_mocks(monkeypatch, features=["bundleId"])
    with pytest.raises(os_agent.OsAgentError, match="空か文字列ではありません"):
        os_agent.tap(0.5, 0.5, bundle_id=bad)
    assert calls["post"] == []


def test_os_agent_features_must_be_a_list(monkeypatch):
    """features が文字列だと `in` が部分一致で通ってしまうので、一覧であることまで見る。"""
    os_agent, calls = _os_agent_with_mocks(monkeypatch, features="bundleIdX")
    with pytest.raises(os_agent.OsAgentError, match="対応していません"):
        os_agent.tap(0.5, 0.5, bundle_id="com.example.app")
    assert calls["post"] == []


def test_os_agent_screenshot_rejects_non_png(monkeypatch):
    """PNG 以外が返ったら失敗にする（壊れた画像を証跡として残さない）。"""
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    monkeypatch.setattr(os_agent, "_request", lambda *a, **k: (b"<html>", "text/html"))
    with pytest.raises(os_agent.OsAgentError, match="スクリーンショットを取得できません"):
        os_agent.screenshot()


def test_os_agent_stop_never_raises(monkeypatch):
    """停止要求の失敗は無視する（後始末はスクリプト側でも行うため、ここで止まらない）。"""
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")

    def boom(*a, **k):
        raise os_agent.OsAgentError("落ちている")

    monkeypatch.setattr(os_agent, "_post", boom)
    os_agent.stop()   # 例外にならないこと


def _os_agent_rotate_mocks(monkeypatch, response=None, error=None):
    """rotate のテスト用。`_post` の送信を記録し、応答か例外を差し替える。"""
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    sent = []

    def fake_post(path, payload, **k):
        sent.append((path, payload))
        if error is not None:
            raise error
        return response if response is not None else {"ok": True, "orientation": payload["orientation"]}

    monkeypatch.setattr(os_agent, "_post", fake_post)
    return os_agent, sent


@pytest.mark.parametrize("bad", ["", "LandscapeLeft", "landscapeleft", "faceUp", "unknown", None, 1])
def test_os_agent_rotate_rejects_bad_names_without_sending(monkeypatch, bad):
    """4 つ以外の名前（大小文字違い・faceUp・型違い）は**送らずに**止める（issue #83）。"""
    os_agent, sent = _os_agent_rotate_mocks(monkeypatch)
    with pytest.raises(os_agent.OsAgentError, match="大小文字を区別"):
        os_agent.rotate(bad)
    assert sent == []


def test_os_agent_rotate_sends_name_and_accepts_matching_readback(monkeypatch):
    """4 つの名前はそのまま送り、読み直した向きが一致すれば戻る。"""
    os_agent, sent = _os_agent_rotate_mocks(monkeypatch)
    for name in os_agent.ORIENTATIONS:
        os_agent.rotate(name)
    assert sent == [("/orientation", {"orientation": n}) for n in os_agent.ORIENTATIONS]


@pytest.mark.parametrize("readback", ["portrait", "unknown", "faceUp", None])
def test_os_agent_rotate_rejects_mismatched_readback(monkeypatch, readback):
    """読み直した向きが送った名前と違えば止める（書き込みが効かない環境への網）。"""
    os_agent, _ = _os_agent_rotate_mocks(monkeypatch, response={"ok": True, "orientation": readback})
    with pytest.raises(os_agent.OsAgentError, match="一致しません"):
        os_agent.rotate("landscapeRight")


def test_os_agent_rotate_translates_unknown_route_404_to_old_agent(monkeypatch):
    """古いエージェントの 404（`unknown:` の本文）は「古い版」の案内に読み替える。**案内文そのものを照合する**
    （読み替えを外しても OsAgentError は投げられるので、型だけでは守れない）。"""
    from e2e_driver import os_agent as m

    old = m.OsAgentError("POST /orientation が失敗（HTTP 404）", http_status=404,
                         body='{"error":"unknown: POST /orientation"}')
    os_agent, _ = _os_agent_rotate_mocks(monkeypatch, error=old)
    with pytest.raises(os_agent.OsAgentError, match="向きの変更（/orientation）に対応していません") as e:
        os_agent.rotate("landscapeLeft")
    assert e.value.http_status == 404


@pytest.mark.parametrize("status, body", [
    (404, '{"error":"not found"}'),   # 同じポートを別のサーバーが握っている等
    (404, "<html>404</html>"),         # JSON でない
    (400, '{"error":"unknown: x"}'),   # 404 以外は本文が何でも読み替えない
])
def test_os_agent_rotate_keeps_other_errors_as_is(monkeypatch, status, body):
    """`unknown:` で始まる 404 以外は読み替えず、元の例外をそのまま出す。"""
    from e2e_driver import os_agent as m

    original = m.OsAgentError(f"POST /orientation が失敗（HTTP {status}）: {body}", http_status=status, body=body)
    os_agent, _ = _os_agent_rotate_mocks(monkeypatch, error=original)
    with pytest.raises(os_agent.OsAgentError) as e:
        os_agent.rotate("landscapeLeft")
    assert e.value is original


def test_os_agent_request_keeps_http_status_and_body(monkeypatch):
    """`_request` は HTTP のエラーの状態コードと本文を例外に残す（rotate の読み替えの材料）。"""
    import io
    import urllib.error
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    payload = b'{"error":"unknown: POST /orientation"}'

    def fake_urlopen(request, timeout):
        raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, io.BytesIO(payload))

    monkeypatch.setattr(os_agent.urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(os_agent.OsAgentError) as e:
        os_agent._post("/orientation", {"orientation": "portrait"})
    assert e.value.http_status == 404
    assert e.value.body == payload.decode()


# ---------------------------------------------------------------------------
# issue #85: OS エージェントのアプリ・要素・ジェスチャ・端末と、device_log
#

def _os_agent_post_recorder(monkeypatch, response=None, features=("bundleId",)):
    """新しい操作のテスト用。`_post` の送信を記録し、bundle_id の事前確認の /status も差し替える。"""
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    monkeypatch.setattr(os_agent, "_BUNDLE_ID_SUPPORTED", set())
    sent = []

    def fake_post(path, payload, **k):
        sent.append((path, payload, k.get("timeout")))
        if response is not None:
            return response
        return {"ok": True, "base": payload.get("bundleId", "springboard")}

    monkeypatch.setattr(os_agent, "_post", fake_post)
    monkeypatch.setattr(os_agent, "status", lambda **k: {"agent": "uapp-os-agent/1.0", "features": list(features)})
    return os_agent, sent


def test_os_agent_new_operations_send_expected_json(monkeypatch):
    """各操作が送るパスと本文（エージェントの約束どおりの名前）。"""
    os_agent, sent = _os_agent_post_recorder(monkeypatch)
    os_agent.app_state("com.example.app")
    os_agent.launch_app("com.example.app", arguments=["-a"], environment={"UAPP_E2E_BRIDGE_PORT": "13383"})
    os_agent.terminate_app("com.example.app")
    os_agent.find_elements(bundle_id="com.apple.mobilesafari", label_contains="Go", type="button", limit=10)
    os_agent.tap_element(identifier="ok", index=1, timeout=3)
    os_agent.wait_element(state="gone", label="Loading")
    os_agent.type_into("hello", clear=True, type="textField")
    os_agent.double_tap(0.5, 0.25)
    os_agent.long_press(0.1, 0.2, duration=2)
    os_agent.pinch("com.example.app", 0.5)
    os_agent.press_button("home")
    os_agent.open_url("myapp://path")
    assert [p for p, _, _ in sent] == ["/app/state", "/app/launch", "/app/terminate", "/elements", "/element/tap",
                                       "/element/wait", "/element/type", "/doubletap", "/longpress", "/pinch",
                                       "/press", "/open-url"]
    body = {p: b for p, b, _ in sent}
    assert body["/app/launch"] == {"bundleId": "com.example.app", "arguments": ["-a"],
                                   "environment": {"UAPP_E2E_BRIDGE_PORT": "13383"}}
    assert body["/elements"] == {"bundleId": "com.apple.mobilesafari", "labelContains": "Go", "type": "button", "limit": 10}
    assert body["/element/tap"] == {"identifier": "ok", "index": 1, "timeout": 3.0}
    assert body["/element/wait"]["state"] == "gone"
    assert body["/element/type"] == {"type": "textField", "text": "hello", "clear": True, "index": 0, "timeout": 5.0}
    assert body["/longpress"] == {"x": 0.1, "y": 0.2, "duration": 2.0}
    assert body["/pinch"] == {"bundleId": "com.example.app", "scale": 0.5}
    # HTTP の時間切れは「所要の上限＋余裕」
    timeouts = {p: t for p, _, t in sent}
    assert timeouts["/element/tap"] == 3 + os_agent.DEFAULT_TIMEOUT
    assert timeouts["/longpress"] == 2 + os_agent.DEFAULT_TIMEOUT
    assert timeouts["/app/launch"] == 90.0


@pytest.mark.parametrize("call", [
    lambda m: m.find_elements(),                              # 指定が何も無い
    lambda m: m.find_elements(type="Button"),                 # 大小文字違い
    lambda m: m.tap_element(label=""),                        # 空文字
    lambda m: m.wait_element(state="Exists", label="x"),
    lambda m: m.tap_element(label="x", timeout=31),           # 上限超え
    lambda m: m.long_press(0.5, 0.5, duration=0),
    lambda m: m.long_press(0.5, 0.5, duration=11),
    lambda m: m.pinch("com.example.app", 0.05),
    lambda m: m.pinch("", 2),
    lambda m: m.press_button("Home"),
    lambda m: m.open_url("no-scheme"),
    lambda m: m.app_state(""),
    lambda m: m.launch_app("com.example.app", arguments="-a"),
    lambda m: m.launch_app("com.example.app", environment={"A": 1}),
])
def test_os_agent_new_operations_reject_bad_input_without_sending(monkeypatch, call):
    """名前・範囲・型の誤りは**送らずに**止める（エージェントと同じ一覧。大小文字を区別）。"""
    os_agent, sent = _os_agent_post_recorder(monkeypatch)
    with pytest.raises(os_agent.OsAgentError):
        call(os_agent)
    assert sent == []


def test_os_agent_new_operation_old_agent_404_is_translated_but_missing_element_is_not(monkeypatch):
    """古い版の 404（`unknown:`）だけを「古い版」と案内する。要素が無い 404 はそのまま（**案内文そのものを照合する**）。"""
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")

    def old_agent(path, payload, **k):
        raise os_agent.OsAgentError("HTTP 404", http_status=404, body='{"error":"unknown: POST /app/state"}')

    monkeypatch.setattr(os_agent, "_post", old_agent)
    with pytest.raises(os_agent.OsAgentError, match="アプリの状態の取得（/app/state）に対応していません"):
        os_agent.app_state("com.example.app")

    missing = os_agent.OsAgentError("HTTP 404", http_status=404, body='{"error":"要素が見つかりません（5.0 秒待った）"}')

    def no_element(path, payload, **k):
        raise missing

    monkeypatch.setattr(os_agent, "_post", no_element)
    with pytest.raises(os_agent.OsAgentError) as e:
        os_agent.tap_element(label="ok")
    assert e.value is missing


def test_os_agent_gestures_with_bundle_id_check_support_and_base(monkeypatch):
    """bundle_id を渡すジェスチャは、既存の tap と同じく押す前に対応を確かめ、応答の base も照合する。"""
    os_agent, sent = _os_agent_post_recorder(monkeypatch, features=())
    with pytest.raises(os_agent.OsAgentError, match="bundle_id"):
        os_agent.double_tap(0.5, 0.5, bundle_id="com.example.app")
    assert sent == []   # 古い版には押さない

    os_agent, sent = _os_agent_post_recorder(monkeypatch, response={"ok": True, "base": "springboard"})
    with pytest.raises(os_agent.OsAgentError, match="base"):
        os_agent.long_press(0.5, 0.5, bundle_id="com.example.app")


class _FakeLogBridge:
    """device_log のテスト用の偽ブリッジ（`logs` だけ）。ページの大きさを小さくして「追いつくまで読む」を確かめる。"""

    def __init__(self, page=2):
        self.session = "s1"
        self.entries = []          # (type, message)
        self.first = 0
        self.dropped = 0
        self.page = page
        self.logEnabled = True
        self.filterLogType = "Log"
        self.unknown = False
        self.calls = 0
        self.off_on_calls = set()   # この番号（0 始まり）の呼び出しだけ logEnabled=False を返す

    def add(self, type_, message):
        self.entries.append((type_, message))

    def logs(self, since=None, max=None):  # noqa: A002
        from e2e_driver.client import BridgeError
        if self.unknown:
            raise BridgeError("UNKNOWN_COMMAND", "unknown command: logs")
        call = self.calls
        self.calls += 1
        enabled = self.logEnabled and call not in self.off_on_calls
        nxt = len(self.entries)
        import builtins   # 引数名 max が組み込みを隠すため
        start = self.first if since is None else builtins.max(since, self.first)
        out = [{"seq": i, "type": t, "message": m, "stack": ""}
               for i, (t, m) in enumerate(self.entries) if i >= start][: self.page]
        return {"session": self.session, "first": self.first, "next": nxt, "dropped": self.dropped,
                "logEnabled": enabled, "filterLogType": self.filterLogType, "entries": out}


@pytest.fixture
def bridge_log(monkeypatch):
    from e2e_driver import device_log
    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    monkeypatch.setattr(device_log, "_mark", None)
    return device_log, _FakeLogBridge()


def test_device_log_android_delegates_to_adb(monkeypatch):
    """Android（エディタでも iOS でもない）は adb のまま（ネイティブのクラッシュや ANR の行も拾えるので変えない）。"""
    from e2e_driver import adb, device_log
    monkeypatch.delenv("UAPP_E2E_IOS", raising=False)
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    calls = []
    monkeypatch.setattr(adb, "clear_logcat", lambda: calls.append("clear"))
    monkeypatch.setattr(adb, "unity_exceptions", lambda: ["E/Unity: NullReferenceException"])
    monkeypatch.setattr(adb, "unity_log", lambda: "log")
    device_log.clear()
    assert device_log.unity_exceptions() == ["E/Unity: NullReferenceException"]
    assert device_log.unity_log() == "log"
    assert calls == ["clear"]


@pytest.mark.parametrize("env", ["UAPP_E2E_IOS", "UAPP_E2E_EDITOR"])
def test_device_log_reads_after_mark_and_pages_until_caught_up(monkeypatch, env, bridge_log):
    """clear() の後ろだけを、**next に追いつくまで**読む（1 回の応答の上限で後半を落とさない）。エディタでも同じ経路。"""
    device_log, fake = bridge_log
    monkeypatch.delenv("UAPP_E2E_IOS", raising=False)
    monkeypatch.setenv(env, "1")
    fake.add("Exception", "before-mark")
    device_log.clear(fake)
    for i in range(5):
        fake.add("Log", f"log{i}")
    fake.add("Error", "late-error")          # ページ（2 件）を何度もまたいだ先
    fake.add("Assert", "late-assert")
    assert device_log.unity_exceptions(fake) == ["Error: late-error", "Assert: late-assert"]
    assert "log4" in device_log.unity_log(fake)


def test_device_log_without_clear_reads_from_start(bridge_log):
    device_log, fake = bridge_log
    fake.add("Exception", "boom")
    assert device_log.unity_exceptions(fake) == ["Exception: boom"]


@pytest.mark.parametrize("breaker, message", [
    (lambda f: setattr(f, "session", "s2"), "起動し直された"),
    (lambda f: setattr(f, "first", 5), "溢れて"),
    (lambda f: setattr(f, "unknown", True), "古い版"),
    (lambda f: setattr(f, "logEnabled", False), "ロガーの設定を変えました"),     # clear のあとに止めた
    (lambda f: setattr(f, "filterLogType", "Error"), "ロガーの設定を変えました"),  # clear のあとに絞った
])
def test_device_log_raises_instead_of_returning_empty(bridge_log, breaker, message):
    """取れていないときは**空の一覧を返さない**（例外が無いことにすると偽の緑になる）。"""
    device_log, fake = bridge_log
    for i in range(3):
        fake.add("Log", f"x{i}")
    device_log.clear(fake)
    for i in range(3, 8):
        fake.add("Log", f"x{i}")
    breaker(fake)
    with pytest.raises(device_log.DeviceLogUnavailableError, match=message):
        device_log.unity_exceptions(fake)


def test_device_log_mark_survives_across_tests_so_relaunch_without_clear_is_detected(bridge_log):
    """印は最後の clear() のものが残る。アプリが起動し直されたあと clear() せずに読むと止まる（偽の赤の側。見落としにはならない）。"""
    device_log, fake = bridge_log
    device_log.clear(fake)                 # 前のテスト
    fake.session = "s2"                    # アプリが起動し直された
    fake.entries = [("Exception", "new-boom")]
    with pytest.raises(device_log.DeviceLogUnavailableError, match="起動し直された"):
        device_log.unity_exceptions(fake)  # 次のテストが clear() せずに読む
    device_log.clear(fake)
    fake.add("Error", "after")
    assert device_log.unity_exceptions(fake) == ["Error: after"]


@pytest.mark.parametrize("setup, message", [
    (lambda f: setattr(f, "logEnabled", False), "ロガーを止めています"),
    (lambda f: setattr(f, "filterLogType", "Exception"), "ロガーを絞っています"),
])
def test_device_log_clear_refuses_when_logger_already_off(bridge_log, setup, message):
    """clear() の前からロガーが止まっている・例外が届かないほど絞られているなら、**clear() の時点で**止める（操作の前に止まる）。"""
    device_log, fake = bridge_log
    setup(fake)
    with pytest.raises(device_log.DeviceLogUnavailableError, match=message):
        device_log.clear(fake)


def test_device_log_detects_logger_stopped_and_restarted_between_reads(bridge_log):
    """clear → ロガーを止める（その間の例外は届かない）→ 戻した状態を読む、の偽の緑。**戻したあとに読んでも、
    clear 時と設定が同じなら検出できない**（残る限界）が、止めたまま読めば必ず止まる。"""
    device_log, fake = bridge_log
    device_log.clear(fake)
    fake.logEnabled = False
    with pytest.raises(device_log.DeviceLogUnavailableError, match="ロガーの設定を変えました"):
        device_log.unity_exceptions(fake)
    fake.logEnabled = True   # 戻すと検出できない（読みの時点の値しか見えない）
    assert device_log.unity_exceptions(fake) == []


@pytest.mark.parametrize("use_clear", [True, False])
@pytest.mark.parametrize("which", ["head", "middle"])
def test_device_log_checks_logger_on_every_response(bridge_log, use_clear, which):
    """読み取りの**どの応答**（最初の応答・途中のページ）でロガーが止まっていても止める。最後の応答だけを見ると偽の緑になる。"""
    device_log, fake = bridge_log
    if use_clear:
        device_log.clear(fake)
    for i in range(7):
        fake.add("Log", f"x{i}")       # ページ（2 件）を何度もまたぐ
    base = fake.calls
    # 読みの呼び出し: base = 最初の応答（page=1）、base+1 以降 = ページ
    fake.off_on_calls = {base} if which == "head" else {base + 2}
    with pytest.raises(device_log.DeviceLogUnavailableError):
        device_log.unity_exceptions(fake)


def test_device_log_filter_warning_still_allows_exceptions_but_not_full_log(bridge_log):
    """filterLogType=Warning なら Exception / Assert / Error は届く（Unity の Logger の規則）。全部のログは取れない扱い。"""
    device_log, fake = bridge_log
    fake.filterLogType = "Warning"
    fake.add("Error", "e")
    assert device_log.unity_exceptions(fake) == ["Error: e"]
    with pytest.raises(device_log.DeviceLogUnavailableError):
        device_log.unity_log(fake)



# ---------------------------------------------------------------------------
# 記録した設定を serve が使う（issue #41）
#
# journey ディレクトリから祖先を遡って `e2e-config.json` を探す形だと、
# **注入モードのようにジャーニーの出力先と対象が別ツリーにある構成**で
# ハブの設定を拾い、**対象と違う uiType・違うポート**で動く。
# 記録した側が「実際に使った設定」を知っているので、それを残して serve へ渡す。


def _layout(tmp_path):
    """ハブ（出力先・uGUI）と対象 clone（NGUI）を作る。"""
    import json
    hub_journey = tmp_path / "hub" / "uapp_e2e" / "Builds" / "journey"
    hub_journey.mkdir(parents=True)
    (tmp_path / "hub" / "uapp_e2e" / "e2e-config.json").write_text(
        json.dumps({"uiType": "ugui", "editorBridgePort": 13343}), encoding="utf-8")
    clone_config = tmp_path / "clone" / "e2e-config.json"
    clone_config.parent.mkdir(parents=True)
    clone_config.write_text(
        json.dumps({"uiType": "ngui", "editorBridgePort": 13344}), encoding="utf-8")
    return hub_journey, clone_config


def _write_journey(out_dir, config_path=None):
    import json
    from e2e_driver import journey
    data = {"format": journey.FORMAT, "screens": [], "transitions": [], "tests": []}
    if config_path is not None:
        data["configPath"] = str(config_path)
    (out_dir / "journey.json").write_text(json.dumps(data), encoding="utf-8")


def _resolved_ui_type(out_dir):
    """**serve が使う本物の解決関数**を通して uiType を決める。

    ここで解決順を再実装すると、**実装を変えてもテストが素通りする**
    （実際に変異テストで検出できなかった）。`resolve_config_start` を呼ぶこと。
    """
    from e2e_driver import journey
    return journey._find_ui_type(journey.resolve_config_start(out_dir))


def test_recorded_config_wins_over_the_search(tmp_path):
    """記録があれば**対象の設定**を使う（探索してハブを拾わない）。"""
    out, clone_config = _layout(tmp_path)
    _write_journey(out, clone_config)
    assert _resolved_ui_type(out) == "ngui"


def test_search_is_used_when_nothing_was_recorded(tmp_path):
    """**対照**: 記録が無い（旧い journey.json）なら従来どおり探索する。

    これが無いと、上のテストが「記録の有無」ではなく別の何かに反応していても気づけない。
    """
    out, _ = _layout(tmp_path)
    _write_journey(out, None)
    assert _resolved_ui_type(out) == "ugui"


def test_recorded_config_that_no_longer_exists_is_ignored(tmp_path):
    """**対照**: 実在しないパスが記録されていたら無視して探索へ落ちる。

    記録は絶対パスなので、journey を別マシンへ持って行くと外れる。
    そこで止まると、レポートが開けなくなる。
    """
    from e2e_driver import journey
    out, _ = _layout(tmp_path)
    _write_journey(out, tmp_path / "nowhere" / "e2e-config.json")
    assert journey._recorded_config(out) is None
    assert _resolved_ui_type(out) == "ugui"


def test_save_records_the_config_path_from_the_environment(tmp_path, monkeypatch):
    """`UAPP_E2E_CONFIG_PATH` があれば journey.json へ残す。"""
    import json
    from e2e_driver import journey
    out, clone_config = _layout(tmp_path)
    monkeypatch.setenv("UAPP_E2E_CONFIG_PATH", str(clone_config))
    journey.JourneyRecorder(client=object(), out_dir=out, enabled=True).save()
    saved = json.loads((out / "journey.json").read_text(encoding="utf-8"))
    assert saved.get("configPath") == str(clone_config)


def test_save_omits_the_config_path_when_unset(tmp_path, monkeypatch):
    """**対照**: 環境変数が無ければ書かない（旧い journey.json と同じ形）。"""
    import json
    from e2e_driver import journey
    out, _ = _layout(tmp_path)
    monkeypatch.delenv("UAPP_E2E_CONFIG_PATH", raising=False)
    journey.JourneyRecorder(client=object(), out_dir=out, enabled=True).save()
    saved = json.loads((out / "journey.json").read_text(encoding="utf-8"))
    assert "configPath" not in saved


def test_os_agent_type_text_warns_once_for_agent_without_focus_check(monkeypatch):
    """typeFocusCheck を持たない古いエージェントには、最初の type_text で 1 回だけ警告する（送ることは止めない）。"""
    from e2e_driver import os_agent

    monkeypatch.setenv("UAPP_E2E_OS_AGENT_URL", "http://127.0.0.1:8200")
    monkeypatch.setattr(os_agent, "_TYPE_FOCUS_WARNED", set())
    monkeypatch.setattr(os_agent, "status", lambda **k: {"agent": "uapp-os-agent/1.0", "features": ["bundleId"]})
    sent = []
    monkeypatch.setattr(os_agent, "_post", lambda path, payload, **k: sent.append(path) or {"ok": True})
    with pytest.warns(UserWarning, match="typeFocusCheck"):
        os_agent.type_text("a", bundle_id="com.example.app")
    import warnings as _w
    with _w.catch_warnings():
        _w.simplefilter("error")
        os_agent.type_text("b", bundle_id="com.example.app")   # 2 回目は警告しない
    assert sent == ["/type", "/type"]
