# adb の要素ベース・ネイティブUI操作（uiautomator XMLパーサ）等の単体テスト。デバイス不要。
import pytest

from e2e_driver import adb
from e2e_driver.adb import find_ui_node

# uiautomator dump の抜粋を模した最小XML（アプリ選択ダイアログ相当）
XML = (
    '<?xml version="1.0"?><hierarchy rotation="1">'
    '<node text="アプリで開く" class="android.widget.TextView" resource-id="" bounds="[100,200][400,260]"/>'
    '<node text="DEV1_D" class="android.widget.TextView" resource-id="" bounds="[1000,500][1300,560]"/>'
    '<node text="1 回のみ" class="android.widget.Button" resource-id="android:id/button_once" bounds="[200,900][600,1000]"/>'
    '<node text="" class="android.widget.EditText" resource-id="acct" bounds="[50,400][900,480]"/>'
    '</hierarchy>')


def test_find_by_text_exact_and_contains():
    assert find_ui_node(text="DEV1_D", xml=XML)["center"] == (1150, 530)
    assert find_ui_node(text="DEV1", xml=XML) is None, "完全一致では部分文字列にヒットしない"
    assert find_ui_node(text="DEV1", contains=True, xml=XML)["center"] == (1150, 530)
    # 全角/半角ゆらぎのある「1 回のみ」を部分一致で拾える
    assert find_ui_node(text="回のみ", contains=True, xml=XML)["resource-id"] == "android:id/button_once"


def test_find_by_class_and_resource_id():
    edit = find_ui_node(class_name="android.widget.EditText", xml=XML)
    assert edit["center"] == (475, 440) and edit["resource-id"] == "acct"
    assert find_ui_node(resource_id="acct", xml=XML)["class"] == "android.widget.EditText"


def test_find_returns_none_when_absent():
    assert find_ui_node(text="存在しない", xml=XML) is None
    assert find_ui_node(class_name="android.webkit.WebView", xml=XML) is None


def test_missing_adb_binary_message(monkeypatch, tmp_path):
    """adb バイナリが無いときは生の FileNotFoundError でなく、導入案内付き RuntimeError にする。

    **接続先の宣言はすべて外してから確かめる**。`UAPP_E2E_IOS` を残したままだと
    iOS 用のガードが先に働き、このテストの期待と食い違う — 導入先が
    `run-ios-e2e.ps1`（`UAPP_E2E_IOS=1` を立てる）から既定の `tests` を回すと
    **必ず 1 件赤くなる**（開発リポは tests を絞っているので露見しなかった）。
    """
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    monkeypatch.delenv("UAPP_E2E_IOS", raising=False)
    def _no_adb(*args, **kwargs):
        raise FileNotFoundError("adb")
    monkeypatch.setattr(adb.subprocess, "run", _no_adb)
    with pytest.raises(adb.AdbNotFoundError, match="adb が見つかりません"):
        adb.forward()
    with pytest.raises(adb.AdbNotFoundError, match="adb が見つかりません"):
        adb.screencap(tmp_path / "screen.png")


def test_module_ports_survive_invalid_env():
    """BRIDGE_PORT/DEVICE_BRIDGE_PORT は無効な環境変数でも import 死せず既定 13333 に落ちる。"""
    import importlib
    try:
        with pytest.MonkeyPatch.context() as mp:
            mp.setenv("UAPP_E2E_BRIDGE_PORT", "abc")
            mp.setenv("UAPP_E2E_DEVICE_PORT", "70000")
            with pytest.warns(UserWarning, match="無視します"):
                reloaded = importlib.reload(adb)
            assert reloaded.BRIDGE_PORT == 13333
            assert reloaded.DEVICE_BRIDGE_PORT == 13333
    finally:
        # 環境変数が実行開始時の値へ戻った状態（context 脱出後）で再ロードし、
        # モジュール定数を元どおりに再構築する（run-e2e 経由等で非既定ポートの場合も正しく復元）
        importlib.reload(adb)


def test_ios_mode_blocks_adb(monkeypatch, tmp_path):
    """UAPP_E2E_IOS=1 中の adb 使用も明示エラー（Android 端末を誤検証しないため）。

    エディタ直結側だけ検査していて iOS 側が無かったため、
    「iOS ガードが先に働く」ことに気づけなかった（0.1.9 のリリース前検証で発覚）。
    """
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    called = []
    monkeypatch.setattr(adb.subprocess, "run", lambda *a, **k: called.append(a))
    with pytest.raises(adb.AdbNotFoundError, match="iOS"):
        adb.forward()
    with pytest.raises(adb.AdbNotFoundError, match="iOS"):
        adb.screencap(tmp_path / "screen.png")
    assert not called, "ガードは subprocess 実行前に効くこと"


def test_editor_mode_blocks_adb(monkeypatch, tmp_path):
    """UAPP_E2E_EDITOR=1 中の adb 使用は明示エラー（端末側を誤検証する偽の成功を防ぐ）。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    called = []
    monkeypatch.setattr(adb.subprocess, "run", lambda *a, **k: called.append(a))
    with pytest.raises(adb.AdbNotFoundError, match="エディタ直結モード"):
        adb.forward()
    with pytest.raises(adb.AdbNotFoundError, match="エディタ直結モード"):
        adb.screencap(tmp_path / "screen.png")
    assert not called, "ガードは subprocess 実行前に効くこと"
