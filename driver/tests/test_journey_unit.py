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
