# BridgeClient の接続先ポート解決とエディタ直結の単体テスト。デバイス・adb 不要。
# 解決順: 明示引数 > 環境変数 UAPP_E2E_BRIDGE_PORT > e2e-config.json の editorBridgePort > 13333
import json
import socket
import threading

import pytest

from e2e_driver.client import (CONFIG_SEARCH_PARENTS, DEFAULT_PORT, BridgeClient,
                               WrongBridgeTargetError, resolve_port)


@pytest.fixture(autouse=True)
def work(monkeypatch, tmp_path):
    """環境変数と CWD を隔離した作業ディレクトリ。**tmp_path をそのまま使わない。**

    e2e-config.json の探索は起点から親を遡るので、pytest の一時領域が導入先ツリーの中に
    ある場合（SETUP.md が案内する `--basetemp ..\\Builds\\pytest-tmp`）、tmp_path の上位に
    ある**実物の** e2e-config.json を拾ってしまい、「設定なし」を前提にしたテストが落ちる。
    探索が tmp_path の外へ出ない深さまで掘り下げ、そこを基準にする
    （深さは実装の CONFIG_SEARCH_PARENTS に追随させる）。
    """
    monkeypatch.delenv("UAPP_E2E_BRIDGE_PORT", raising=False)
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    root = tmp_path.joinpath(*[f"w{i}" for i in range(CONFIG_SEARCH_PARENTS + 1)])
    root.mkdir(parents=True)
    monkeypatch.chdir(root)
    return root


def _write_config(dir_path, port):
    (dir_path / "e2e-config.json").write_text(
        json.dumps({"editorBridgePort": port}), encoding="utf-8")


def test_explicit_arg_wins(monkeypatch, work):
    monkeypatch.setenv("UAPP_E2E_BRIDGE_PORT", "14000")
    _write_config(work, 13399)
    assert resolve_port(15000) == 15000
    assert BridgeClient(port=15000).port == 15000


def test_env_wins_over_config(monkeypatch, work):
    _write_config(work, 13399)
    monkeypatch.setenv("UAPP_E2E_BRIDGE_PORT", "14000")
    assert resolve_port() == 14000


def test_config_found_from_subdirectory(monkeypatch, work):
    # <プロジェクト>/uapp_e2e/driver/tests からの実行を模し、親を辿って解決できること
    _write_config(work, 13399)
    sub = work / "driver" / "tests"
    sub.mkdir(parents=True)
    monkeypatch.chdir(sub)
    assert resolve_port() == 13399
    assert BridgeClient().port == 13399


def test_default_without_env_and_config(work):
    assert resolve_port() == DEFAULT_PORT


@pytest.mark.parametrize("env_value", ["70000", "0", "-1", "abc", "13_333"])
def test_invalid_env_skipped_to_next_candidate(monkeypatch, work, env_value):
    """値域外・不正な環境変数は（Unity側と同じく）スキップして次候補へ。片側だけの採用を防ぐ。"""
    monkeypatch.setenv("UAPP_E2E_BRIDGE_PORT", env_value)
    with pytest.warns(UserWarning, match="無視します"):
        assert resolve_port() == DEFAULT_PORT  # config なし → 既定へ
    _write_config(work, 13399)
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
def test_broken_config_falls_back_to_default(work, content):
    (work / "e2e-config.json").write_text(content, encoding="utf-8")
    assert resolve_port() == DEFAULT_PORT


def test_resolve_port_start_overrides_cwd(monkeypatch, work):
    """探索起点 start を指定すると CWD ではなくそこから探す（journey serve が使う）。"""
    journey_side = work / "proj" / "Builds" / "journey"
    journey_side.mkdir(parents=True)
    _write_config(work / "proj", 13398)
    elsewhere = work / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)  # CWD 側には config が無い
    assert resolve_port(start=journey_side) == 13398
    assert resolve_port() == DEFAULT_PORT


class _FakeBridge:
    """行区切りJSONで ping に応答する最小サーバー（エディタ再生ブリッジの代役）。"""

    def __init__(self, platform="FakeEditor"):
        self.platform = platform
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
            result = {"bridge": "1.0"}
            if self.platform is not None:
                result["platform"] = self.platform
            response = {"id": request["id"], "ok": True, "result": result}
            conn.sendall((json.dumps(response) + "\n").encode("utf-8"))


def test_editor_direct_connect_via_config(monkeypatch, work):
    """引数・環境変数・adb なしで、e2e-config.json の editorBridgePort だけで接続できる。"""
    bridge = _FakeBridge()
    _write_config(work, bridge.port)
    client = BridgeClient(timeout=5.0)
    assert client.port == bridge.port
    assert client.connect(retries=1).ping()["platform"] == "FakeEditor"
    client.close()


# --- エディタ直結モードで接続先がエディタであることの検証 -------------------
# デバイス実行が残した adb forward が editorBridgePort と同じ番号を握っていると、
# エディタへ繋いだつもりで端末のアプリを検証してしまう（＝偽の緑）。2026-08-03 に実際に踏んだ。

def test_editor_mode_rejects_non_editor_target(monkeypatch, work):
    """UAPP_E2E_EDITOR=1 で端末側（platform=Android）に繋がったら明示的に失敗する。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    bridge = _FakeBridge(platform="Android")
    _write_config(work, bridge.port)
    with pytest.raises(WrongBridgeTargetError) as e:
        BridgeClient(timeout=5.0).connect(retries=1)
    # 原因と対処が読み取れること（メッセージが痩せる退行を防ぐ）
    assert "adb forward" in str(e.value)
    assert "Android" in str(e.value)


def test_editor_mode_rejects_missing_platform(monkeypatch, work):
    """platform が無い応答も通さない（相手が E2EBridge でない/壊れている。fail-closed）。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    bridge = _FakeBridge(platform=None)
    _write_config(work, bridge.port)
    with pytest.raises(WrongBridgeTargetError):
        BridgeClient(timeout=5.0).connect(retries=1)


def test_editor_mode_accepts_editor_target(monkeypatch, work):
    """エディタ（platform が Editor で終わる）なら素通しする。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    bridge = _FakeBridge(platform="OSXEditor")
    _write_config(work, bridge.port)
    client = BridgeClient(timeout=5.0).connect(retries=1)
    assert client.ping()["platform"] == "OSXEditor"
    client.close()


def test_device_mode_does_not_check_target(monkeypatch, work):
    """デバイス経路（ポートは環境変数で渡る）では判定しない。

    **`run-e2e.ps1` のデバイス経路は UAPP_E2E_BRIDGE_PORT で forward 先を渡す**ので、
    ポートの解決元は env になる。ここを判定対象にすると端末への正当な接続が全部止まる。
    """
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    bridge = _FakeBridge(platform="Android")
    _write_config(work, 19999)                       # 設定はあるが env が優先される
    monkeypatch.setenv("UAPP_E2E_BRIDGE_PORT", str(bridge.port))
    client = BridgeClient(timeout=5.0).connect(retries=1)
    assert client.ping()["platform"] == "Android"
    client.close()


def test_manual_connection_without_declaration_is_not_checked(monkeypatch, work):
    """**宣言が無い接続は検査しない**（誤検知ゼロを優先した明示的な線引き）。

    「ポートの解決元からエディタ意図を推定する」形はレビューで捨てた — 解決元では
    手動デバイス接続（`BridgeClient(port=<ホスト側ポート>)`）と手動エディタ接続を
    分離できず、どちらかが必ず壊れるため。呼び手の意図は `UAPP_E2E_EDITOR=1` でだけ表明する。
    """
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    monkeypatch.delenv("UAPP_E2E_BRIDGE_PORT", raising=False)
    bridge = _FakeBridge(platform="Android")
    _write_config(work, bridge.port)
    # 明示ポート・設定由来・既定のいずれでも素通し（デバイスへの正当な手動接続を壊さない）
    for client in (BridgeClient(port=bridge.port, timeout=5.0),):
        c = client.connect(retries=1)
        assert c.ping()["platform"] == "Android"
        c.close()


def test_declared_editor_mode_is_checked_regardless_of_port_source(monkeypatch, work):
    """宣言があれば、ポートの解決元（明示/環境変数/設定）に関わらず検査する。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    for use_env in (False, True):
        bridge = _FakeBridge(platform="Android")
        if use_env:
            monkeypatch.setenv("UAPP_E2E_BRIDGE_PORT", str(bridge.port))
            with pytest.raises(WrongBridgeTargetError):
                BridgeClient(timeout=5.0).connect(retries=1)
            monkeypatch.delenv("UAPP_E2E_BRIDGE_PORT")
        else:
            with pytest.raises(WrongBridgeTargetError):
                BridgeClient(port=bridge.port, timeout=5.0).connect(retries=1)
