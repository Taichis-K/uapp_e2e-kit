# BridgeClient の接続先ポート解決とエディタ直結の単体テスト。デバイス・adb 不要。
# 解決順: 明示引数 > 環境変数 UAPP_E2E_BRIDGE_PORT > e2e-config.json の editorBridgePort > 13333
import json
import socket
import threading

import pytest

from e2e_driver.client import DEFAULT_PORT, BridgeClient, resolve_port


@pytest.fixture(autouse=True)
def _isolate(monkeypatch, tmp_path):
    """環境変数と CWD を隔離する（実行元の e2e-config.json やポート設定を拾わないように）。"""
    monkeypatch.delenv("UAPP_E2E_BRIDGE_PORT", raising=False)
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    monkeypatch.chdir(tmp_path)


def _write_config(dir_path, port):
    (dir_path / "e2e-config.json").write_text(
        json.dumps({"editorBridgePort": port}), encoding="utf-8")


def test_explicit_arg_wins(monkeypatch, tmp_path):
    monkeypatch.setenv("UAPP_E2E_BRIDGE_PORT", "14000")
    _write_config(tmp_path, 13399)
    assert resolve_port(15000) == 15000
    assert BridgeClient(port=15000).port == 15000


def test_env_wins_over_config(monkeypatch, tmp_path):
    _write_config(tmp_path, 13399)
    monkeypatch.setenv("UAPP_E2E_BRIDGE_PORT", "14000")
    assert resolve_port() == 14000


def test_config_found_from_subdirectory(monkeypatch, tmp_path):
    # <プロジェクト>/uapp_e2e/driver/tests からの実行を模し、親を辿って解決できること
    _write_config(tmp_path, 13399)
    sub = tmp_path / "driver" / "tests"
    sub.mkdir(parents=True)
    monkeypatch.chdir(sub)
    assert resolve_port() == 13399
    assert BridgeClient().port == 13399


def test_default_without_env_and_config(tmp_path):
    assert resolve_port() == DEFAULT_PORT


@pytest.mark.parametrize("env_value", ["70000", "0", "-1", "abc", "13_333"])
def test_invalid_env_skipped_to_next_candidate(monkeypatch, tmp_path, env_value):
    """値域外・不正な環境変数は（Unity側と同じく）スキップして次候補へ。片側だけの採用を防ぐ。"""
    monkeypatch.setenv("UAPP_E2E_BRIDGE_PORT", env_value)
    with pytest.warns(UserWarning, match="無視します"):
        assert resolve_port() == DEFAULT_PORT  # config なし → 既定へ
    _write_config(tmp_path, 13399)
    with pytest.warns(UserWarning, match="無視します"):
        assert resolve_port() == 13399  # config あり → config を採用


@pytest.mark.parametrize("bad_port", [0, -1, 70000, True, 13.5, "13_333"])
def test_explicit_invalid_raises(bad_port):
    """明示引数の値域外・非整数は暗黙フォールバックせず即時失敗（意図しないポートへの接続を防ぐ）。

    bool/float/アンダースコア表記は環境変数・config 経路と同じ厳格パースで拒否する。
    """
    with pytest.raises(ValueError, match="有効なポートではありません"):
        resolve_port(bad_port)
    with pytest.raises(ValueError, match="有効なポートではありません"):
        BridgeClient(port=bad_port)


@pytest.mark.parametrize("content", [
    "{broken",                              # JSON構文エラー
    "[1, 2, 3]",                            # ルートが配列（.get が無い）
    '{"editorBridgePort": [13399]}',        # 値の型が想定外（int() 不可）
    '{"editorBridgePort": "abc"}',          # 数値化できない文字列
    '{"editorBridgePort": 0}',              # 値域外（Unity側は正の値のみ採用）
    '{"editorBridgePort": -1}',             # 値域外（負数）
    '{"editorBridgePort": 70000}',          # 値域外（65535超）
    '{"editorBridgePort": "13_333"}',       # Pythonのint()は通るがC#のTryParseは拒否する表記
    '{"editorBridgePort": true}',           # bool（int()だと1に化けてしまう。C#はキャスト失敗）
])
def test_broken_config_falls_back_to_default(tmp_path, content):
    (tmp_path / "e2e-config.json").write_text(content, encoding="utf-8")
    assert resolve_port() == DEFAULT_PORT


def test_resolve_port_start_overrides_cwd(monkeypatch, tmp_path):
    """探索起点 start を指定すると CWD ではなくそこから探す（journey serve が使う）。"""
    journey_side = tmp_path / "proj" / "Builds" / "journey"
    journey_side.mkdir(parents=True)
    _write_config(tmp_path / "proj", 13398)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)  # CWD 側には config が無い
    assert resolve_port(start=journey_side) == 13398
    assert resolve_port() == DEFAULT_PORT


class _FakeBridge:
    """行区切りJSONで ping に応答する最小サーバー（エディタ再生ブリッジの代役）。"""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        conn, _ = self.sock.accept()
        reader = conn.makefile("r", encoding="utf-8", newline="\n")
        for line in reader:
            request = json.loads(line)
            response = {"id": request["id"], "ok": True,
                        "result": {"bridge": "1.0", "platform": "FakeEditor"}}
            conn.sendall((json.dumps(response) + "\n").encode("utf-8"))


def test_editor_direct_connect_via_config(monkeypatch, tmp_path):
    """引数・環境変数・adb なしで、e2e-config.json の editorBridgePort だけで接続できる。"""
    bridge = _FakeBridge()
    _write_config(tmp_path, bridge.port)
    client = BridgeClient(timeout=5.0)
    assert client.port == bridge.port
    assert client.connect(retries=1).ping()["platform"] == "FakeEditor"
    client.close()
