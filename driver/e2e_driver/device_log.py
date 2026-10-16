"""テスト中のアプリのログと例外（プラットフォームを問わない口。issue #85）。

Android は今までどおり adb（`adb.clear_logcat` / `unity_log` / `unity_exceptions`）。
iOS とエディタ直結は、ブリッジの `logs` コマンド（アプリの中のリングバッファ）で読む ―
iOS では Unity の `Debug.Log` が OS のログに出ず、標準出力にしか出ないため。

    from e2e_driver import device_log
    device_log.clear(client)
    ...操作...
    assert not device_log.unity_exceptions(client)

**取れていないときは空の一覧を返さない**（例外が無いことにすると偽の緑になる）。
アプリが起動し直された・溢れて読めない区間がある・ブリッジが古い・アプリがロガーを止めている、のどれかなら
`DeviceLogUnavailableError` を投げる。
"""
from __future__ import annotations

import os

from . import adb
from .client import BridgeClient, BridgeError

# Unity の LogType のうち「例外」として返すもの。**Android（adb）の「Exception か Error: を含む行」より厳しい** ―
# Debug.LogError はすべて数える。エディタでは Play 中のエディタ側のエラー（インポート・拡張・パッケージ）も混ざる
EXCEPTION_TYPES = ("Exception", "Assert", "Error")
# 例外を取るのに要る filterLogType（Unity の Logger は Exception を常に通し、それ以外は 型 <= filterLogType。
# 並びは Error, Assert, Warning, Log, Exception）。Error だと Assert が、Exception だと Error と Assert が落ちる
_FILTERS_FOR_EXCEPTIONS = ("Log", "Warning", "Assert")
_PAGE = 500
_MAX_PAGES = 100   # 2000 件のバッファを読むのに十分（進まない応答への保険）


class DeviceLogUnavailableError(RuntimeError):
    """ログを取れていない（例外が無いとは言えない）。"""


# ブリッジ経路で clear() が覚えた位置（セッション ID, 次の seq）。**最後の clear() のものがプロセスの間ずっと残る**ので、
# アプリを起動し直したあとに clear() せずに読むと「起動し直された」で止まる（偽の赤の側。テストの初めに clear() する）
# (session, next, logEnabled, filterLogType)。ロガーの設定も覚え、読むときに変わっていれば止める
_mark: tuple[str, int, bool, str] | None = None


def _uses_bridge() -> bool:
    """判定の順: エディタ直結 → iOS → それ以外（Android）。"""
    return os.environ.get("UAPP_E2E_EDITOR") == "1" or os.environ.get("UAPP_E2E_IOS") == "1"


def _client(client: BridgeClient | None) -> BridgeClient:
    return client if client is not None else BridgeClient().connect()


def _call(client: BridgeClient, since: int | None, page: int = _PAGE) -> dict:
    try:
        return client.logs(since=since, max=page)
    except BridgeError as e:
        if e.code == "UNKNOWN_COMMAND":
            raise DeviceLogUnavailableError(
                "アプリのブリッジがログの取得（logs）に対応していません（古い版）。新しいキットでアプリをビルドし直してください"
            ) from e
        raise


def clear(client: BridgeClient | None = None) -> None:
    """ここから後ろのログだけを見るように印を付ける。

    **アプリがロガーを止めている・例外が届かないほど絞っているなら、ここで `DeviceLogUnavailableError`**
    （操作の前に止まる。印だけ付けて読むときに判定すると、途中でロガーを戻されたとき例外を見落とす＝偽の緑）。
    """
    global _mark
    if not _uses_bridge():
        adb.clear_logcat()
        return
    head = _call(_client(client), None, page=1)   # 位置だけ欲しいので 1 件で足りる
    _require(head, _FILTERS_FOR_EXCEPTIONS, "例外の検出")
    _mark = (head["session"], int(head["next"]), bool(head.get("logEnabled", True)), str(head.get("filterLogType", "Log")))


def _read(client: BridgeClient | None, allowed_filters: tuple[str, ...], what: str) -> list[dict]:
    """覚えた位置から最新まで読む（応答の上限で途中が落ちないよう、next に追いつくまで繰り返す）。

    **ロガーの検査は、最初の応答を含むすべての応答で行う**（最後の応答だけを見ると、途中で止まっていた区間の
    例外を見落としたまま、最後が正常なら空の一覧を返してしまう＝偽の緑）。
    """
    c = _client(client)
    head = _call(c, None, page=1)
    _check_logger(head, allowed_filters, what)
    session = head["session"]
    if _mark is None:
        since = int(head["first"])          # clear() 前は、そのセッションの先頭（残っている最も古い位置）から
        if int(head["dropped"]) > 0:
            raise DeviceLogUnavailableError("clear() の前に溢れていて、セッションの先頭を読めません（先に clear() する）")
    else:
        if _mark[0] != session:
            raise DeviceLogUnavailableError(
                "アプリが起動し直されたため、前の起動のログを読めません（繋ぎ直したあと clear() し直す）"
            )
        since = _mark[1]
    entries: list[dict] = []
    for _ in range(_MAX_PAGES):
        page = _call(c, since)
        _check_logger(page, allowed_filters, what)
        if page["session"] != session:
            raise DeviceLogUnavailableError("読んでいる途中でアプリが起動し直されました")
        if since < int(page["first"]):
            raise DeviceLogUnavailableError(
                f"ログが溢れて、読めていない区間があります（読みたかった位置 {since} / 残っている最も古い位置 {page['first']}）"
            )
        got = page["entries"]
        entries.extend(got)
        if not got:
            break                                   # 追いついた（未読があれば少なくとも 1 件返る約束）
        since = int(got[-1]["seq"]) + 1
        if since >= int(page["next"]):
            break
    else:
        raise DeviceLogUnavailableError("ログを最後まで読めませんでした（応答が進みません）")
    return entries


def _check_logger(meta: dict, allowed_filters: tuple[str, ...], what: str) -> None:
    """1 つの応答について、clear() 時と設定が同じか・止めて／絞っていないかを確かめる。"""
    _same_logger(meta)
    _require(meta, allowed_filters, what)


def _same_logger(meta: dict) -> None:
    """clear() の時点とロガーの設定が変わっていたら止める（途中で止めて戻した場合などに、間の例外を見落とさないため）。
    **clear() と読みのあいだで切って、読む前に元へ戻した場合は検出できない**（残る限界）。"""
    if _mark is None:
        return
    now = (bool(meta.get("logEnabled", True)), str(meta.get("filterLogType", "Log")))
    if now != (_mark[2], _mark[3]):
        raise DeviceLogUnavailableError(
            f"clear() のあとにアプリがロガーの設定を変えました（clear 時: logEnabled={_mark[2]} filterLogType={_mark[3]} / "
            f"今: logEnabled={now[0]} filterLogType={now[1]}）。間の例外を見落としうるので判定しません"
        )


def _require(meta: dict, allowed_filters: tuple[str, ...], what: str) -> None:
    if not meta.get("logEnabled", True):
        raise DeviceLogUnavailableError(
            f"アプリがロガーを止めています（Debug.unityLogger.logEnabled = false）。{what}は Debug.* の分が届きません"
        )
    if meta.get("filterLogType", "Log") not in allowed_filters:
        raise DeviceLogUnavailableError(
            f"アプリがロガーを絞っています（filterLogType = {meta.get('filterLogType')}）。{what}に要るログが届きません"
        )


def unity_log(client: BridgeClient | None = None) -> str:
    """印から後ろのアプリのログ（1 件 1 行の `<type>: <message>`）。"""
    if not _uses_bridge():
        return adb.unity_log()
    entries = _read(client, ("Log",), "全部のログ")
    return "\n".join(f"{e['type']}: {e['message']}" for e in entries)


def unity_exceptions(client: BridgeClient | None = None) -> list[str]:
    """印から後ろの例外・エラー（`Exception` / `Assert` / `Error`）。"""
    if not _uses_bridge():
        return adb.unity_exceptions()
    entries = _read(client, _FILTERS_FOR_EXCEPTIONS, "例外の検出")
    return [f"{e['type']}: {e['message']}" for e in entries if e["type"] in EXCEPTION_TYPES]


def dump_all(client: BridgeClient | None = None) -> str:
    """バッファに残っている全件（失敗証跡用。溢れていても読める範囲を返す）。"""
    c = _client(client)
    head = _call(c, None)
    since = int(head["first"])
    lines = [f"# session={head['session']} first={head['first']} next={head['next']} dropped={head['dropped']} "
             f"logEnabled={head['logEnabled']} filterLogType={head['filterLogType']}"]
    for _ in range(_MAX_PAGES):
        page = _call(c, since)
        got = page["entries"]
        for e in got:
            lines.append(f"[{e['seq']}] {e['type']}: {e['message']}")
            if e.get("stack"):
                lines.extend("    " + s for s in e["stack"].splitlines())
        if not got:
            break
        since = int(got[-1]["seq"]) + 1
        if since >= int(page["next"]):
            break
    return "\n".join(lines)
