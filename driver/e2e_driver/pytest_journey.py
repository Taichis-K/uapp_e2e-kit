"""pytest 連携: キットの基本フィクスチャ（client / g）とジャーニー記録（docs/07-viewer.md）。

tests/conftest.py が star-import して pytest に見せる（pytest>=8 は rootdir 外 conftest の
pytest_plugins を許さないため、この取り込み方にしている）。**フィクスチャの実体をこの
パッケージ側に置くことで、キット更新は e2e_driver/ の差し替えだけで完結する**
（conftest.py は初回導入時に生成された後は上書きされない）。

ジャーニー記録の有効化は `--journey <DIR>` オプションか環境変数 UAPP_E2E_JOURNEY_DIR。
未指定時、journey フィクスチャは no-op レコーダーを返すので、テストは記録の有無を意識しなくてよい。
"""
from __future__ import annotations

import os
import time

import pytest

from . import adb
from .client import BridgeClient
from .gestures import Gestures
from .journey import JourneyRecorder
from .metrics import MetricsRecorder

__all__ = ["pytest_addoption", "pytest_runtest_makereport",
           "client", "g", "journey", "_journey_test_context"]


@pytest.fixture(scope="session")
def client():
    """接続済みブリッジクライアント。アプリ未起動なら分かりやすく失敗させる。

    UAPP_E2E_EDITOR=1 なら adb を使わずエディタ再生へ直結する（デバイス/AVD不要。
    ポートは BridgeClient が e2e-config.json の editorBridgePort を自動解決）。

    デバイス向けは、Unityビルド等がadbサーバーを再起動するとforwardが消えるため、
    リトライのたびに forward を張り直す（IL2CPPコールドスタートは30秒超、
    エミュレーターが高負荷だと100秒超かかることもある）。
    リトライ回数は環境変数 UAPP_E2E_CONNECT_RETRIES（既定: デバイス120秒相当・エディタ30秒相当）。
    起動が長いアプリは増やす。
    """
    if os.environ.get("UAPP_E2E_EDITOR") == "1":
        c = BridgeClient()
        try:
            c.connect(retries=int(os.environ.get("UAPP_E2E_CONNECT_RETRIES", "30")), interval=1.0)
        except ConnectionError:
            pytest.fail(f"エディタ再生の E2EBridge（port={c.port}）に接続できません。"
                        f"Unityエディタが再生中か、ポート設定"
                        f"（UAPP_E2E_BRIDGE_PORT > e2e-config.json の editorBridgePort）を確認してください")
        yield c
        c.close()
        return
    if os.environ.get("UAPP_E2E_IOS") == "1":
        # iOS シミュレータのアプリはホストのポートで直接待ち受ける（adb forward 相当は不要）。
        # ポートは run-ios-e2e.ps1 が UAPP_E2E_BRIDGE_PORT で渡す（接続先の検証は
        # client 側の UAPP_E2E_IOS ガードが行う: platform=IPhonePlayer 以外は明示エラー）
        c = BridgeClient()
        try:
            c.connect(retries=int(os.environ.get("UAPP_E2E_CONNECT_RETRIES", "30")), interval=1.0)
        except ConnectionError:
            pytest.fail(f"iOS シミュレータの E2EBridge（port={c.port}）に接続できません。"
                        f"アプリが起動しているか、ポート設定"
                        f"（UAPP_E2E_BRIDGE_PORT / e2e-config.json の iosSimulatorPort）を確認してください")
        yield c
        c.close()
        return
    # デバイス向けは forward したホスト側ポートに固定する（e2e-config.json の
    # editorBridgePort への自動フォールバックでエディタへ誤接続しないように）
    c = BridgeClient(port=adb.BRIDGE_PORT)
    last_error = None
    for _ in range(int(os.environ.get("UAPP_E2E_CONNECT_RETRIES", "120"))):
        try:
            adb.forward()
            c.connect(retries=1, interval=0)
            break
        except adb.AdbNotFoundError as e:
            pytest.fail(str(e))  # adb 不在は恒久エラー。リトライで2分待たせない
        except (ConnectionError, RuntimeError) as e:
            last_error = e
            time.sleep(1.0)
    else:
        pytest.fail(f"E2EBridge に接続できません: {last_error}")
    yield c
    c.close()


@pytest.fixture()
def g(client):
    """ジェスチャヘルパー。テスト終了時に押しっぱなしポインタを必ず解放する。"""
    gestures = Gestures(client)
    yield gestures
    client.pointer_reset()


def pytest_addoption(parser):
    parser.addoption(
        "--journey", metavar="DIR", default=None,
        help="ジャーニー記録（画面・遷移・カバレッジ）の出力先ディレクトリ。"
             "未指定時は環境変数 UAPP_E2E_JOURNEY_DIR、それも無ければ記録しない")
    parser.addoption(
        "--metrics", metavar="DIR", default=None,
        help="計測記録（issue #49）の出力先ディレクトリ。未指定時は環境変数 UAPP_E2E_METRICS_DIR、"
             "それも無ければ記録しない。journey（画面と遷移）とは別の層で、"
             "**その回の目的と設定を先頭行に書く**ことで後から比較してよいかを判断できる")
    parser.addoption(
        "--runbootstrap", action="store_true", default=False,
        help="クリーンインストールを伴うブートストラップ（アプリ削除→導入→アカウント作成→"
             "ワールド到達）を実行する。未指定だと該当テストはスキップされる")


@pytest.fixture(scope="session")
def journey(request, client):
    """ジャーニーレコーダー。テストは画面の節目で journey.capture(<画面id>) を呼ぶ。"""
    out_dir = request.config.getoption("--journey") or os.environ.get("UAPP_E2E_JOURNEY_DIR")
    recorder = JourneyRecorder(client, out_dir, enabled=bool(out_dir))
    request.config._uapp_e2e_journey = recorder
    yield recorder
    recorder.save()


@pytest.fixture(scope="session")
def metrics(request):
    """計測レコーダー（issue #49）。**既定は無効**で、`--metrics <DIR>` か
    環境変数 `UAPP_E2E_METRICS_DIR` を渡したときだけ書く。

    使い方は「**最初に目的と設定を宣言してから測る**」:

        metrics.begin("ステージ1の所要時間", build="Release", debugAssist=False)
        metrics.record("stage1_seconds", 42.5)

    **合否は判定しない**（記録するだけ）。「回復しうる値の減少」で成功を判定しない、
    という規約は `docs/ai-loop.md` を参照。
    """
    out_dir = request.config.getoption("--metrics") or os.environ.get("UAPP_E2E_METRICS_DIR")
    recorder = MetricsRecorder(out_dir, enabled=bool(out_dir))
    yield recorder
    recorder.save()


@pytest.fixture(autouse=True)
def _journey_test_context(request):
    """journey を使うテストの操作ログを nodeid に紐付ける。"""
    if "journey" not in request.fixturenames:
        yield
        return
    recorder = request.getfixturevalue("journey")
    recorder.current_test = request.node.nodeid
    yield
    recorder.current_test = None


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    recorder = getattr(item.config, "_uapp_e2e_journey", None)
    if recorder is None or not recorder.enabled or "journey" not in item.fixturenames:
        return
    if report.when == "call":
        recorder.record_test(item.nodeid, report.outcome, report.duration)
    elif report.when == "setup" and report.outcome != "passed":
        # setup 失敗（error）/ skip は call フェーズが無いのでここで確定する
        recorder.record_test(item.nodeid, "error" if report.failed else report.outcome,
                             report.duration)
