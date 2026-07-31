"""ブリッジ疎通のスモーク（キット所有・常時配布）。

導入直後は自作テストがまだ無く、`tests` にはデバイス不要の単体テストしか入っていない。
その状態で run-e2e が「N passed」を返しても、**ブリッジには一度も接続していない**ので
導入検証としては空振りになる（導入先で実際に起きた）。既定の `tests`（ディレクトリ指定）で
実行する限りこのテストが必ず混ざるので、run-e2e 経由の passed が疎通の証明を含む。

**ただし「必ず含まれる」ことを保証はしない**: `-PytestArgs "-k …"` / `--deselect` で外れるし、
e2e-config.json の `tests` を個別ファイルへ絞れば収集されない。導入検証のときは
結果に `test_bridge_ping` の PASSED があることを目で確かめること。

run-e2e 経由でない実行（ブリッジ無しの単体テストだけの実行）では自動スキップする:
エディタ直結は UAPP_E2E_EDITOR=1、デバイスは UAPP_E2E_BRIDGE_PORT が run-e2e から渡る。
"""
import os

import pytest

pytestmark = pytest.mark.skipif(
    os.environ.get("UAPP_E2E_EDITOR") != "1" and not os.environ.get("UAPP_E2E_BRIDGE_PORT"),
    reason="run-e2e 経由の実行でのみ疎通を検証する（ブリッジ無しの実行ではスキップ）",
)


def test_bridge_ping(client):
    """接続してプロトコルの応答が返ること＝計装のコンパイル・待受・ポート解決の一括検証。"""
    info = client.ping()
    assert info["bridge"] == "1.0"
    assert info["screen"]["w"] > 0 and info["screen"]["h"] > 0
    assert "ngui" in info
