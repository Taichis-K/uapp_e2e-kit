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


def test_input_reset_releases_a_stuck_pointer(client):
    """**`input_reset()` は押されたままのポインタも解放する**（issue #54）。

    異常終了（常駐スクリプトを kill する等）で押下が残ると、以後のタップが全部
    `POINTER_ALREADY_DOWN` で落ちる。以前の `input_reset` はキー・マウス・パッドしか
    見ておらず `released: 0` を返すだけだったので、**名前と実装が食い違っていた**。

    **症状は「特定のボタンが効かない」に見える** ― 導入先は倍率ボタンの探索が
    1 件しか返らないのを見て「このボタンは実機では効かない」と結論しかけた
    （実際はタップが 1 回も通っていなかった）。

    **対照を対にする**: 押下が無いときは `releasedPointers` が 0 であること。
    これが無いと「常に何か解放したと言う」実装でもこのテストは通る。
    """
    # 対照: 何も押していない状態
    client.input_reset()
    assert client.input_reset().get("releasedPointers") == 0, \
        "押していないのに解放したと言っている"

    # 押しっぱなしを作る（up を打たない＝異常終了の再現）
    client.pointer_down(1, 10, 10)
    try:
        with pytest.raises(Exception) as caught:
            client.pointer_down(1, 10, 10)
        assert "pointer_up" in str(caught.value) or "input_reset" in str(caught.value), \
            f"次の一手が書かれていない: {caught.value}"

        result = client.input_reset()
        assert result.get("releasedPointers") == 1, f"解放されていない: {result}"
    finally:
        # 失敗しても後続のテストへ押下を持ち越さない
        client.input_reset()

    # 解放後は同じ id で押し直せる
    client.pointer_down(1, 10, 10)
    client.pointer_up(1)


def test_texts_collects_only_the_requested_types(client):
    """`texts` は**指定した型だけ**を、**呼び手が指定した範囲から**集める（issue #56）。

    **型も範囲もブリッジは推測しない。** 型ごとに起点を変える案は捨てた
    （3D 系が Canvas の下にいることもあり、型から置き場所は決まらない）。

    **`dump` との集合一致は契約にしない** ― `dump` の `text` は名前の部分一致で拾う
    別の判定なので、どのスコープと比べても一致するとは限らない。
    境界（Canvas 外・空文字・スコープ）は EditMode の `BridgeTextsTests` で固定する。

    ここで見るのは**実機／エディタで実際に通ること**、**`scope` が効くこと**、
    **打ち間違いが黙って飲み込まれないこと**。
    """
    types = ["UnityEngine.UI.Text", "TMPro.TextMeshProUGUI", "UILabel"]
    ui = client.texts(types=types)
    assert ui["unknownTypes"] == [] or all(
        t in ("TMPro.TextMeshProUGUI", "UILabel") for t in ui["unknownTypes"]
    ), f"このプロジェクトに在るはずの型が解決できていない: {ui['unknownTypes']}"
    assert ui["resolvedTypes"], "解決できた型が 1 つも無い"
    for entry in ui["resolvedTypes"]:
        # **返るのは型と件数だけ**（起点は型ではなく `scope` が決める）
        assert set(entry) == {"type", "count"}, f"resolvedTypes の形が違う: {entry}"

    # 既定の範囲はシーン全体で、応答がそれを申告する
    assert ui["scope"] == "scene", f"既定の scope が scene でない: {ui['scope']}"

    paths = {i["path"] for i in ui["items"]}
    assert paths, "テキストが 1 件も取れていない（サンプルには必ずある）"

    # **`scope` は絞るだけ**（既定より広くならない）。
    # Canvas / UIRoot を持たない構成では空になるが、それは指定どおりで正しい
    for scope in ("canvas", "ngui"):
        narrowed = client.texts(types=types, scope=scope)
        assert narrowed["scope"] == scope, f"scope が申告されない: {narrowed}"
        assert {i["path"] for i in narrowed["items"]} <= paths, (
            f"scope={scope} が既定より広い集合を返した"
        )

    # パス指定は**その配下だけ**。起点自身は含まれる
    target = sorted(paths)[0]
    subtree = client.texts(types=types, scope=target)
    assert subtree["scope"] == target
    assert target in {i["path"] for i in subtree["items"]}, (
        f"パス指定の起点自身が返らない: {target}"
    )

    # **短い名前が実行環境で落ちないこと**。`Text` は非 Component の同名が
    # 別アセンブリに居る（`System.Net.Mime.MediaTypeNames+Text` など）ので、
    # 以前は列挙順しだいで INTERNAL の NullReferenceException になっていた。
    # **どの型が読み込まれているかは実行環境で変わる**ので、ここで押さえる価値がある
    short = client.texts(types=["Text"])
    assert short["unknownTypes"] == [], f"短い名前 'Text' が解決できていない: {short}"
    assert [e["type"] for e in short["resolvedTypes"]] == ["UnityEngine.UI.Text"], (
        f"非 Component の同名を掴んでいる: {short['resolvedTypes']}"
    )

    # **打ち間違いを黙って飲み込まない**（偽の緑を防ぐ一次情報）
    probe = client.texts(types=["UnityEngine.UI.Text", "NoSuchTextType"])
    assert probe["unknownTypes"] == ["NoSuchTextType"],         f"解決できない型が報告されない: {probe.get('unknownTypes')}"
