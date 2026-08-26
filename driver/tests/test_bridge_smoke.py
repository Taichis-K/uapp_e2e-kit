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


def _hittable_paths(dump_result: dict) -> set[str]:
    """dump の結果から hittable == True のパスを集める（子孫まで再帰）。"""
    found: set[str] = set()

    def walk(node: dict) -> None:
        if node.get("hittable") is True:
            found.add(node["path"])
        for child in node.get("children", []):
            walk(child)

    for root in dump_result.get("nodes", []):
        walk(root)
    return found


def test_hittables_matches_dump(client):
    """`hittables` は `dump(probe="all")` の hittable 集合と一致する（issue #45）。

    **これがこのコマンドの仕様そのもの**。`hittables` は階層走査をせずに
    「矩形を持てるもの」を直接列挙するため、**列挙元を間違えると静かに取りこぼす** ―
    uGUI で `Selectable` だけに絞ると Selectable を持たない Image が落ち、
    NGUI でコライダーだけに絞るとボタンの中の UIWidget が落ちる（どちらも実測）。
    件数の一致ではなく**集合の一致**を見るので、取りこぼしも余計な混入も検出できる。

    scope="scene" と比べるのは、`hittables` が読み込み済みの全シーン（DontDestroyOnLoad 含む）を
    見るため。scope="ui" だと Canvas / NGUI ルート配下しか出ず、比較の土俵が違う。
    """
    dumped = _hittable_paths(client.dump(scope="scene", probe="all"))
    listed = {item["path"] for item in client.hittables()["items"]}

    missing = dumped - listed
    extra = listed - dumped
    assert not missing, f"hittables が取りこぼした: {sorted(missing)[:10]}"
    assert not extra, f"hittables に余計なものが入った: {sorted(extra)[:10]}"


def test_dump_active_only_drops_inactive_branches(client):
    """`activeOnly=True` で非アクティブな枝が消え、既定（False）では消えないこと（issue #45）。

    **既定を変えていないこと**の対照でもある ―「ダイアログは存在するがまだ非アクティブ」を
    確認する使い方があるので、既定で消すと黙って壊れる。
    """
    def paths(result: dict) -> set[str]:
        out: set[str] = set()

        def walk(node: dict) -> None:
            out.add(node["path"])
            for child in node.get("children", []):
                walk(child)

        for root in result.get("nodes", []):
            walk(root)
        return out

    full = paths(client.dump(scope="scene", probe="none"))
    active = paths(client.dump(scope="scene", probe="none", active_only=True))

    assert active <= full, "activeOnly で増えるものがあってはならない"

    # **空振りの緑を可視化する。** 非アクティブな枝が 1 つも無いシーンでは、この比較は
    # 何も確かめていない（`full == active` でも通ってしまう）。**通ったのに証明が無い**状態を
    # 隠さないよう、その場合は skip して理由を残す
    inactive = full - active
    if not inactive:
        pytest.skip(
            f"このシーンには非アクティブな枝が無いため activeOnly の効果を確かめられない"
            f"（全 {len(full)} 件がアクティブ）"
        )
    assert len(active) < len(full), f"activeOnly で {len(inactive)} 件減るはず"


def test_get_accepts_short_and_fully_qualified_type_names(client):
    """`get` は短い型名と完全修飾名の**どちらでも**同じ値を返す（issue #48）。

    以前は `GetType().Name` だけを見ていたので、`UnityEngine.RectTransform` のような
    名前空間付きは **NOT_FOUND** になっていた（導入先の報告）。
    **受け入れる側に倒すのが安全** ― 完全修飾名のほうが条件は厳しいので曖昧さは増えない。
    """
    # どの UI 構成でも必ず在るものを対象にする（uGUI は RectTransform、NGUI は Transform）
    dumped = client.dump(scope="scene", probe="none")

    def first_path(nodes):
        for node in nodes:
            yield node["path"]
            yield from first_path(node.get("children", []))

    target = next(iter(first_path(dumped["nodes"])), None)
    assert target, "dump が 1 件も返さなかった"

    short = client.get(target, "Transform", "childCount")
    full = client.get(target, "UnityEngine.Transform", "childCount")
    assert short == full, f"短い型名と完全修飾名で結果が違う: {short} != {full}"
