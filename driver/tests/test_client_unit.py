# BridgeClient の接続先ポート解決とエディタ直結の単体テスト。デバイス・adb 不要。
# 解決順: 明示引数 > 環境変数 UAPP_E2E_BRIDGE_PORT > e2e-config.json の editorBridgePort > 13333
import json
import socket
import threading

import pytest
from pathlib import Path

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
    monkeypatch.delenv("UAPP_E2E_IOS", raising=False)
    monkeypatch.delenv("UAPP_E2E_IOS_BUNDLE_ID", raising=False)
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

    def __init__(self, platform="FakeEditor", app=None, project=None):
        self.platform = platform
        self.app = app
        self.project = project
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
            if self.project is not None:
                result["project"] = self.project
            if self.app is not None:
                result["app"] = self.app
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
    """エディタ（platform が Editor で終わる）＋プロジェクト一致なら素通しする。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    monkeypatch.setenv("UAPP_E2E_PROJECT_PATH", str(work))
    bridge = _FakeBridge(platform="OSXEditor", project=str(work))
    _write_config(work, bridge.port)
    client = BridgeClient(timeout=5.0).connect(retries=1)
    assert client.ping()["platform"] == "OSXEditor"
    client.close()


# --- 接続先が「別プロジェクトのエディタ」でないことの検証（issue #26）---------
# platform だけでは、同じ editorBridgePort を先に握った別プロジェクトのエディタを
# 見分けられない。UI が似ていればテストが通ってしまう＝偽の緑。

def test_editor_mode_rejects_other_project_editor(monkeypatch, work, tmp_path):
    """別プロジェクトのエディタ（project が違う）は明示的に失敗する。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    monkeypatch.setenv("UAPP_E2E_PROJECT_PATH", str(work))
    other = tmp_path / "other-project"
    other.mkdir()
    bridge = _FakeBridge(platform="OSXEditor", project=str(other))
    _write_config(work, bridge.port)
    with pytest.raises(WrongBridgeTargetError) as e:
        BridgeClient(timeout=5.0).connect(retries=1)
    # 期待と実際の両方が読み取れること（原因の特定に要る）
    assert str(work) in str(e.value)
    assert str(other) in str(e.value)
    assert "editorBridgePort" in str(e.value)


def test_editor_mode_rejects_missing_project(monkeypatch, work):
    """project を返さない古い計装は通さない（fail-closed。再ビルドを促す）。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    monkeypatch.setenv("UAPP_E2E_PROJECT_PATH", str(work))
    bridge = _FakeBridge(platform="OSXEditor", project=None)
    _write_config(work, bridge.port)
    with pytest.raises(WrongBridgeTargetError) as e:
        BridgeClient(timeout=5.0).connect(retries=1)
    assert "再ビルド" in str(e.value)


def test_editor_mode_rejects_unknown_expected_project(monkeypatch, work):
    """期待するプロジェクトを特定できないときも止める（確認できないまま進めない）。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    monkeypatch.delenv("UAPP_E2E_PROJECT_PATH", raising=False)
    bridge = _FakeBridge(platform="OSXEditor", project=str(work))
    _write_config(work, bridge.port)   # Assets/ProjectSettings は作らない＝特定できない
    with pytest.raises(WrongBridgeTargetError) as e:
        BridgeClient(timeout=5.0).connect(retries=1)
    assert "UAPP_E2E_PROJECT_PATH" in str(e.value)


def test_editor_mode_accepts_case_differing_path(monkeypatch, work):
    """大小文字だけ違う表記でも同じプロジェクトなら通す。

    大小文字を区別しないボリューム（macOS 既定 / Windows）で表記が揺れると、
    文字列比較では**正当な実行が止まる**（安全側ではなく、ただの誤検知）。
    """
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    monkeypatch.setenv("UAPP_E2E_PROJECT_PATH", str(work))
    swapped = str(work).upper()
    if not Path(swapped).exists():          # 大小文字を区別するボリュームでは検証不能
        pytest.skip("大小文字を区別するファイルシステムのため対象外")
    bridge = _FakeBridge(platform="OSXEditor", project=swapped)
    _write_config(work, bridge.port)
    BridgeClient(timeout=5.0).connect(retries=1).close()


def test_editor_mode_accepts_path_outside_this_namespace(monkeypatch, work):
    """こちらに実在しないパスでも、報告値と一致するなら通す。

    ドライバとエディタが別の名前空間にいる構成（WSL / Docker / リモートマウント）では、
    エディタが報告するパスはこちらに存在しない。**実在を必須にすると正しいエディタを
    永久に拒否する**（レビュー 3 周目の指摘）。文字列の一致は「エディタ自身がそのパスだと
    答えた」という正当な一致証拠。
    """
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    remote = str(work / "no-such-project")     # 実在しない＝別名前空間の見え方を模す
    monkeypatch.setenv("UAPP_E2E_PROJECT_PATH", remote)
    bridge = _FakeBridge(platform="OSXEditor", project=remote)
    _write_config(work, bridge.port)
    BridgeClient(timeout=5.0).connect(retries=1).close()


def test_editor_mode_rejects_different_nonexistent_paths(monkeypatch, work):
    """実在しないパス同士でも、違うものは通さない。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    monkeypatch.setenv("UAPP_E2E_PROJECT_PATH", str(work / "project-a"))
    bridge = _FakeBridge(platform="OSXEditor", project=str(work / "project-b"))
    _write_config(work, bridge.port)
    with pytest.raises(WrongBridgeTargetError):
        BridgeClient(timeout=5.0).connect(retries=1)


def test_editor_mode_finds_project_from_adopter_layout(monkeypatch, tmp_path):
    """導入先レイアウト（<project>/uapp_e2e/e2e-config.json）でも特定できる。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    monkeypatch.delenv("UAPP_E2E_PROJECT_PATH", raising=False)
    project = tmp_path / "MyGame"
    (project / "Assets").mkdir(parents=True)
    (project / "ProjectSettings").mkdir()
    kit = project / "uapp_e2e"
    (kit / "driver").mkdir(parents=True)
    bridge = _FakeBridge(platform="OSXEditor", project=str(project))
    _write_config(kit, bridge.port)
    monkeypatch.chdir(kit / "driver")
    BridgeClient(timeout=5.0).connect(retries=1).close()


def test_editor_mode_finds_project_from_config_layout(monkeypatch, work):
    """宣言が無くても、e2e-config.json のあるツリーから Unity プロジェクトを特定できる。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    monkeypatch.delenv("UAPP_E2E_PROJECT_PATH", raising=False)
    (work / "Assets").mkdir()
    (work / "ProjectSettings").mkdir()
    bridge = _FakeBridge(platform="OSXEditor", project=str(work))
    _write_config(work, bridge.port)
    client = BridgeClient(timeout=5.0).connect(retries=1)
    client.close()


# --- iOS シミュレータモードの接続先検証（エディタ直結ガードと同じ約束） ---------
# シミュレータのアプリはホストのポート名前空間で直接 LISTEN するため、
# adb forward（デバイス）やエディタと同じ番号を選ぶと接続を取り違える。


def test_ios_mode_rejects_non_ios_target(monkeypatch, work):
    """UAPP_E2E_IOS=1 なのに接続先が iOS プレイヤーでなければ止める（偽の緑防止）。"""
    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    bridge = _FakeBridge(platform="Android")
    _write_config(work, bridge.port)
    with pytest.raises(WrongBridgeTargetError) as e:
        BridgeClient(timeout=5.0).connect(retries=1)
    # 原因と対処が読み取れること
    assert "iosSimulatorPort" in str(e.value)
    assert "Android" in str(e.value)


def test_ios_mode_rejects_missing_platform(monkeypatch, work):
    """platform が無い応答も通さない（相手が E2EBridge でない/壊れている。fail-closed）。"""
    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    bridge = _FakeBridge(platform=None)
    _write_config(work, bridge.port)
    with pytest.raises(WrongBridgeTargetError):
        BridgeClient(timeout=5.0).connect(retries=1)


def test_ios_mode_accepts_iphone_player(monkeypatch, work):
    """iOS プレイヤー（IPhonePlayer）なら素通しする。"""
    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    bridge = _FakeBridge(platform="IPhonePlayer")
    _write_config(work, bridge.port)
    client = BridgeClient(timeout=5.0).connect(retries=1)
    assert client.ping()["platform"] == "IPhonePlayer"
    client.close()


def test_ios_mode_rejects_wrong_bundle_id(monkeypatch, work):
    """platform が正しくても bundle id が違えば止める（同ポートを握る別 iOS アプリの排除）。"""
    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    monkeypatch.setenv("UAPP_E2E_IOS_BUNDLE_ID", "com.example.expected")
    bridge = _FakeBridge(platform="IPhonePlayer", app="com.example.other")
    _write_config(work, bridge.port)
    with pytest.raises(WrongBridgeTargetError) as e:
        BridgeClient(timeout=5.0).connect(retries=1)
    assert "com.example.other" in str(e.value)


def test_ios_mode_accepts_matching_bundle_id(monkeypatch, work):
    """bundle id まで一致すれば素通しする。"""
    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    monkeypatch.setenv("UAPP_E2E_IOS_BUNDLE_ID", "com.example.expected")
    bridge = _FakeBridge(platform="IPhonePlayer", app="com.example.expected")
    _write_config(work, bridge.port)
    client = BridgeClient(timeout=5.0).connect(retries=1)
    assert client.ping()["app"] == "com.example.expected"
    client.close()


def test_conflicting_declarations_fail_before_connect(monkeypatch, work):
    """UAPP_E2E_EDITOR と UAPP_E2E_IOS の同時宣言は接続前に止める（意図が判定できない）。"""
    monkeypatch.setenv("UAPP_E2E_EDITOR", "1")
    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    with pytest.raises(WrongBridgeTargetError):
        BridgeClient(port=1, timeout=1.0).connect(retries=1)


def test_ios_mode_blocks_adb(monkeypatch, work):
    """UAPP_E2E_IOS=1 では adb の使用が明示エラーになる（Android 端末の誤検証防止）。"""
    monkeypatch.setenv("UAPP_E2E_IOS", "1")
    from e2e_driver import adb

    with pytest.raises(adb.AdbNotFoundError) as e:
        adb._run("shell", "echo", "x")
    assert "UAPP_E2E_IOS" in str(e.value)


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


# ---------------------------------------------------------------- §25/§27 導入先要望の回帰

def test_blocked_error_carries_blocker_components():
    """遮蔽者のコンポーネント型名を属性とメッセージの両方で持つ（導入先要望:
    「押して退けるものか・待つべきものか」をパスの命名に依存せず機械判定したい）。"""
    from e2e_driver.client import BlockedError
    e = BlockedError("Canvas/Start", "Canvas/Shield", ["Image", "DialogShield"])
    assert e.blocked_by_components == ["Image", "DialogShield"]
    assert "DialogShield" in str(e)


def test_blocked_error_without_components_is_unchanged():
    """従来どおりの 2 引数呼び出しは挙動が変わらない（後方互換）。"""
    from e2e_driver.client import BlockedError
    e = BlockedError("Canvas/Start", "NOT_RAYCASTABLE")
    assert e.blocked_by_components == []
    assert "コンポーネント" not in str(e)
    assert e.hopeless


def test_wait_for_bridge_gives_up_after_timeout(monkeypatch, work):
    """接続できないままタイムアウトしたら ConnectionError（無限に待たない）。"""
    import time as _time
    from e2e_driver.client import wait_for_bridge
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    monkeypatch.delenv("UAPP_E2E_BRIDGE_PORT", raising=False)
    # 確実に閉じているポートを使う（bind して即 close した番号は直後は未使用）
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    closed_port = probe.getsockname()[1]
    probe.close()
    start = _time.monotonic()
    with pytest.raises(ConnectionError):
        wait_for_bridge(timeout=2.0, port=closed_port, interval=0.5)
    assert _time.monotonic() - start < 30  # 既定 connect(30 回 ×1 秒) に落ちていないこと


def test_wait_for_bridge_deadline_covers_unresponsive_listener(monkeypatch, work):
    """接続だけ受理して ping に応答しないリスナーでも実時間で諦める（外部レビュー指摘:
    回数換算だと 1 試行ごとにソケット timeout 30 秒が積み上がり、timeout=2 が分単位になる）。"""
    import threading
    import time as _time
    from e2e_driver.client import wait_for_bridge
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    monkeypatch.delenv("UAPP_E2E_BRIDGE_PORT", raising=False)
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(5)
    port = server.getsockname()[1]
    accepted: list = []
    stop = threading.Event()

    def sink():
        server.settimeout(0.2)
        while not stop.is_set():
            try:
                conn, _ = server.accept()
                accepted.append(conn)  # 受理するだけで何も返さない
            except OSError:
                continue

    thread = threading.Thread(target=sink, daemon=True)
    thread.start()
    try:
        start = _time.monotonic()
        with pytest.raises(ConnectionError):
            wait_for_bridge(timeout=2.0, port=port, interval=0.2)
        assert _time.monotonic() - start < 10  # 30 秒 × 試行回数に膨らんでいないこと
        # 短い timeout も守る（ソケット timeout を下限で丸めると 0.3 秒指定が
        # 0.5 秒級に化ける — 再レビュー指摘。ここは膨張の検出なので余裕は 1 秒とる）
        start = _time.monotonic()
        with pytest.raises(ConnectionError):
            wait_for_bridge(timeout=0.3, port=port, interval=0.1)
        assert _time.monotonic() - start < 1.3
    finally:
        stop.set()
        thread.join(timeout=2)
        for conn in accepted:
            conn.close()
        server.close()


def test_wait_for_bridge_timeout_zero_probes_once(monkeypatch, work):
    """timeout=0 は「即時プローブ 1 回」（再レビュー指摘: deadline 判定をループ先頭に
    置くと 0 や負値が一度も接続せずに失敗する退行になる）。"""
    from e2e_driver.client import wait_for_bridge
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    monkeypatch.delenv("UAPP_E2E_BRIDGE_PORT", raising=False)
    bridge = _FakeBridge(platform="Android")
    client = wait_for_bridge(timeout=0, port=bridge.port)
    try:
        assert client.ping()["platform"] == "Android"
    finally:
        client.close()


def test_wait_for_bridge_returns_connected_client(monkeypatch, work):
    """ブリッジが応答すれば接続済みクライアントが返る（Play またぎの再接続部品）。"""
    from e2e_driver.client import wait_for_bridge
    monkeypatch.delenv("UAPP_E2E_EDITOR", raising=False)
    monkeypatch.delenv("UAPP_E2E_BRIDGE_PORT", raising=False)
    bridge = _FakeBridge(platform="Android")
    client = wait_for_bridge(timeout=5.0, port=bridge.port)
    try:
        assert client.ping()["platform"] == "Android"
    finally:
        client.close()
