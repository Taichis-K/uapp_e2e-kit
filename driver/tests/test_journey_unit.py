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
