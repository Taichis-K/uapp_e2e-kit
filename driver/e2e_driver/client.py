"""E2EBridge（Unityアプリ内計装サーバー）への行区切りJSONクライアント。

座標系はすべて Unity スクリーン座標（左下原点・ピクセル）。
接続先ポートは 明示引数 > 環境変数 UAPP_E2E_BRIDGE_PORT > e2e-config.json の
editorBridgePort > 13333 の順で解決する（resolve_port 参照）。
"""
from __future__ import annotations

import base64
import json
import os
import re
import socket
import time
import warnings
from pathlib import Path
from typing import Any

DEFAULT_PORT = 13333

# e2e-config.json を探すときに起点から遡る親の数。
# 導入先レイアウト（<プロジェクト>/uapp_e2e/driver/tests から実行 → 設定は uapp_e2e/ 直下）を
# 拾える深さで、それ以上は遡らない。**無制限にすると、たまたま上位にある無関係な設定を
# 拾ってしまう**（pytest の一時領域を導入先ツリー内に置いた場合など）
CONFIG_SEARCH_PARENTS = 4

_PORT_RE = re.compile(r"[+-]?[0-9]+")


def _parse_port(raw) -> int | None:
    """C#側（int.TryParse）と受理範囲を揃えた厳格なポート解釈。値域は 1〜65535。

    Python の int() は "13_333" や bool（True→1）も通してしまい、Unity 側と
    「どちらか片方だけ採用」の不整合を生むため、符号＋10進数字のみを受理する。
    不採用は None（呼び出し側が次の候補へフォールバックする）。
    """
    if isinstance(raw, bool):
        return None
    if isinstance(raw, int):
        port = raw
    elif isinstance(raw, str) and _PORT_RE.fullmatch(raw.strip()):
        port = int(raw.strip())
    else:
        return None
    return port if 1 <= port <= 65535 else None


def _env_port(name: str) -> int | None:
    """環境変数から検証済みポートを取得。未設定は None、無効値は警告して None。"""
    raw = os.environ.get(name)
    if not raw:
        return None
    port = _parse_port(raw)
    if port is None:
        warnings.warn(f"{name}={raw} は有効なポート（1〜65535の10進整数）でないため無視します")
    return port


def _config_editor_port(start: Path | None = None) -> int | None:
    """start（既定: カレントディレクトリ）から親を辿って e2e-config.json の editorBridgePort を拾う。

    ポート未指定の BridgeClient() の典型用途はエディタ再生への直結
    （デバイス向けは run-e2e.ps1 が UAPP_E2E_BRIDGE_PORT で forward 先を渡してくる）。
    設定が無い・読めない・値の型が想定外の場合は None（既定値へフォールバック）。
    """
    start = Path(start) if start is not None else Path.cwd()
    for parent in [start, *list(start.parents)[:CONFIG_SEARCH_PARENTS]]:
        config = parent / "e2e-config.json"
        if config.exists():
            try:
                value = json.loads(config.read_text(encoding="utf-8")).get("editorBridgePort")
                if value is None:
                    return None
                port = _parse_port(value)
                if port is None:
                    warnings.warn(f"{config} の editorBridgePort={value!r} は有効なポートでないため無視します")
                return port
            except Exception:
                return None
    return None


def resolve_port(explicit: int | None = None, start: Path | None = None) -> int:
    """接続先ホストポートの解決: 明示引数 > UAPP_E2E_BRIDGE_PORT > e2e-config.json > 13333。

    start は e2e-config.json の探索起点（既定: カレントディレクトリ）。
    値域は 1〜65535（BridgeHost.ResolvePort と同一）。環境変数・設定ファイルの値域外/不正値は
    警告して次の候補へスキップし、Unity 側と接続先がズレないようにする。
    明示引数の値域外だけは ValueError — 暗黙フォールバックすると呼び出し側の意図と
    別のポートへ接続してしまうため、即時に失敗させる。
    """
    if explicit is not None:
        port = _parse_port(explicit)
        if port is None:
            raise ValueError(f"port {explicit!r} は有効なポートではありません（1〜65535の10進整数）")
        return port
    env_port = _env_port("UAPP_E2E_BRIDGE_PORT")
    if env_port is not None:
        return env_port
    config_port = _config_editor_port(start)
    if config_port is not None:
        return config_port
    return DEFAULT_PORT



class BridgeError(Exception):
    """ブリッジが返したプロトコルエラー。code で機械的に分岐できる。"""

    def __init__(self, code: str, message: str):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message


class WrongBridgeTargetError(Exception):
    """エディタ直結モードなのに、エディタ以外のブリッジへ繋がっている。

    **偽の緑を防ぐためのガード**（`adb.py` の adb 使用ガードと同じ趣旨）。
    典型は「デバイス実行が残した `adb forward` が `editorBridgePort` と同じ番号を握っており、
    エディタへ繋いだつもりがエミュレーター/実機のアプリへ転送されている」ケース。
    **別プロジェクトのアプリなら派手に落ちて気づけるが、同じアプリが端末にも入っていると
    そのまま成功してしまう**（2026-08-03 に実際に踏んだ）。

    **リトライしても直らない**ので `BridgeError` / `OSError` は継承しない
    （`connect()` の再試行ループに拾わせない）。
    """


class BlockedError(Exception):
    """タップ対象に実タッチが届かない。理由は `blocked_by` に入る。

    **待てば解ける遮蔽と、待っても永久に押せない状態を区別する**。混ぜると
    `wait_until_hittable` でタイムアウトまで待つ無駄が起きる（実導入で報告）。
    """

    #: 待っても解決しない理由（対象自身の問題）。それ以外は遮蔽オブジェクトのパス
    HOPELESS = {
        "NOT_RAYCASTABLE": "対象（と子孫）に raycast を受ける要素が無い。指しているパスが違う",
        "NO_EVENTSYSTEM": "シーンに EventSystem が無い",
        "INACTIVE": "対象が非アクティブ",
    }

    def __init__(self, path: str, blocked_by: str, blocked_by_components: list[str] | None = None):
        hint = self.HOPELESS.get(blocked_by)
        detail = f"'{path}' is blocked by '{blocked_by}'"
        if hint:
            detail += f" — {hint}（待っても変わらない）"
        if blocked_by_components:
            # 遮蔽者のコンポーネント型名。**押して退けるものか・待つべきものか**を
            # 呼び手が機械判定するための材料（例: 独自の Shield クラス名が入る。
            # パスの命名に依存した判定をしなくて済む）
            detail += f"（遮蔽者のコンポーネント: {', '.join(blocked_by_components)}）"
        super().__init__(detail)
        self.path = path
        self.blocked_by = blocked_by
        self.blocked_by_components: list[str] = list(blocked_by_components or [])

    @property
    def hopeless(self) -> bool:
        """待っても解決しない種類か（呼び手が再試行の要否を判断できる）。"""
        return self.blocked_by in self.HOPELESS


def _expected_project_path(start: Path | None = None) -> Path | None:
    """エディタ直結で「繋がるべき Unity プロジェクト」の絶対パス。

    解決順は 明示宣言 > 設定ファイルの位置。
      1. 環境変数 `UAPP_E2E_PROJECT_PATH`（`run-e2e.ps1 -Editor` が渡す）
      2. `e2e-config.json` を親方向へ探し、そこから `Assets/` と `ProjectSettings/` を
         持つディレクトリを特定する（開発リポは設定と同じ階層、導入先は 1 つ上）

    どちらも決まらなければ None（呼び出し側が fail-closed で扱う）。
    """
    declared = os.environ.get("UAPP_E2E_PROJECT_PATH")
    if declared:
        return Path(declared).resolve()
    start = Path(start) if start is not None else Path.cwd()
    for parent in [start, *list(start.parents)[:CONFIG_SEARCH_PARENTS]]:
        if not (parent / "e2e-config.json").exists():
            continue
        # 設定と同じ階層（開発リポのサンプル）か、1 つ上（導入先の uapp_e2e/ 配下）
        for candidate in (parent, parent.parent):
            if (candidate / "Assets").is_dir() and (candidate / "ProjectSettings").is_dir():
                return candidate.resolve()
        return None
    return None


def _same_project(a: Path, b: str) -> bool:
    """プロジェクトパスの一致判定。

    **実体が同じかどうかで判定する**（`Path.samefile`＝inode/デバイスの一致）。
    文字列比較だと、**大小文字を区別しないボリューム**（macOS の既定・Windows）で
    表記が違うだけの同じプロジェクトを拒否してしまう（実測で `samefile=True` なのに
    文字列比較は不一致）。**これは安全側ではなく、正当な実行を止めるだけ**。
    別プロジェクトが inode を共有することはないので、実体比較で緩くなる方向は無い。

    どちらかが存在しないときだけ、シンボリックリンクを解決した文字列で比べる
    （macOS の /tmp → /private/tmp のような差を吸収する）。
    """
    other = Path(b)
    # **報告側が手元に実在することは要求しない**。ドライバとエディタが別の名前空間に
    # いる構成（WSL / Docker / リモートマウント。Unity が `D:\repo\Game`、ドライバが
    # `/mnt/d/repo/Game` を見る等）では、報告されたパスはこちらに存在しない。
    # **文字列が一致するなら「エディタ自身がそのパスだと答えた」という正当な一致証拠**なので、
    # 実在を必須にすると正しいエディタを永久に拒否する（レビュー 3 周目の指摘）。
    # そういう構成では `UAPP_E2E_PROJECT_PATH` に**エディタが報告する側のパス**を設定する
    try:
        if a.exists() and other.exists() and a.samefile(other):
            # **inode が 0 の実装を信用しない**。Windows の一部の仮想ボリューム
            # （クラウドドライブ・WebDAV）は st_dev / st_ino に 0 を返し、
            # **別のファイルでも samefile が真**になる（CPython の既知問題）。
            # その場合は下のパス比較で判断する
            if a.stat().st_ino != 0:
                return True
    except OSError:
        pass
    # 大小文字の扱いは OS に合わせる（normcase は Windows でのみ小文字化する）。
    # 実在するものは realpath でシンボリックリンクを解決してから比べる
    # （存在しないパスに realpath をかけても実害は無いが、意味があるのは実在時だけ）
    try:
        return (os.path.normcase(os.path.realpath(a))
                == os.path.normcase(os.path.realpath(other)))
    except OSError:
        return os.path.normcase(str(a)) == os.path.normcase(str(other))


def _check_editor_target(info: dict[str, Any], host: str, port: int) -> None:
    """`UAPP_E2E_EDITOR=1` なのにエディタ以外へ繋がっていたら明示的に失敗させる。

    ping の `platform` は `Application.platform`（エディタなら `OSXEditor` /
    `WindowsEditor` / `LinuxEditor`、実機なら `Android` 等）。**このフィールドは
    E2EBridge の初版から返っている**ので、欠けていたら「相手が E2EBridge ではない」
    か「壊れている」— どちらにせよ黙って先へ進めない（fail-closed）。

    原因を列挙して当てにいくのではなく、**接続先そのものを確かめる**形にしてある
    （`adb forward` の残骸以外にも、同じポートを別プロセスが握る経路はありうるため）。
    """
    # **判定条件は `UAPP_E2E_EDITOR=1` だけ**（`adb.py` の adb 使用ガードと同じ約束）。
    #
    # 「ポートの解決元からエディタ意図を推定する」形を試して**捨てた**（レビュー 2〜5 周目）。
    # 解決元では手動デバイス接続と手動エディタ接続を分離できないため:
    #   - 解決元が env 以外＝エディタ、とすると **`BridgeClient(port=<ホスト側ポート>)` の
    #     手動デバイス接続**（同梱フィクスチャ・`journey serve --bridge-port`・文書の手順）が全滅する
    #   - 逆に env を素通しにすると、`UAPP_E2E_BRIDGE_PORT` は**汎用のポート指定**なので、
    #     それを使った手動エディタ接続で偽の緑が再発する
    # **同じ情報源からは両立できない**。呼び手の意図は呼び手にしか分からないので、
    # 明示的な宣言（この環境変数）だけを根拠にする。
    #
    # 宣言し忘れた手動接続は検査されないが、**それは「誤検知ゼロ」と引き換えの明示的な線引き**。
    # 手順側で `UAPP_E2E_EDITOR=1` を付けることで担保する（docs / スキルに明記）。
    if os.environ.get("UAPP_E2E_EDITOR") != "1":
        return
    platform = str(info.get("platform", ""))
    if platform.endswith("Editor"):
        _check_editor_project(info, host, port)
        return
    detail = f"platform={platform!r}" if platform else "ping の応答に platform がありません"
    raise WrongBridgeTargetError(
        f"エディタ直結の接続（{host}:{port}）なのに、"
        f"接続先がエディタではありません（{detail}）。"
        "エディタのつもりで端末のアプリを検証してしまう（＝偽の緑になりうる）ため中断しました。\n"
        "  典型原因: デバイス実行が残した adb forward が editorBridgePort と同じ番号を握っている。\n"
        "  確認: adb forward --list / このポートの待受が adb かどうか"
        "（mac・Linux: lsof -nP -iTCP:<port> -sTCP:LISTEN、Windows: Get-NetTCPConnection -LocalPort <port>）\n"
        "  対処: adb forward --remove-all、恒久策は e2e-config.json の editorBridgePort を"
        "**ホスト側の forward ポート**（config/local.json の bridgePort / run-e2e.ps1 -HostPort）と"
        "別番号にする（devicePort と分けるだけでは足りない）"
    )


def _check_editor_project(info: dict[str, Any], host: str, port: int) -> None:
    """**どのプロジェクトのエディタか**まで確かめる（issue #26）。

    `platform` が `*Editor` でも、**同じ `editorBridgePort` を先に握った別プロジェクトの
    エディタ**なら通ってしまう（先着が待ち受け、後発は bind に失敗して待つ構図）。
    UI が似ていればテストは通り、**偽の緑**になる。

    照合は ping の `project`（エディタの `dataPath` の親＝プロジェクトルート）と、
    こちら側が期待するプロジェクトパス。**どちらかが欠けたら止める**（fail-closed）—
    「確かめられなかった」を「一致した」として先へ進めると、ガードが有名無実になる。
    """
    reported = info.get("project")
    if not reported:
        raise WrongBridgeTargetError(
            f"接続先のエディタ（{host}:{port}）が、どのプロジェクトかを返しません。\n"
            "  E2EBridge が古い可能性があります（ping の project は後から追加されました）。"
            "**導入先で再ビルド**するか、エディタを開き直してください。\n"
            "  この照合が無いと、同じ editorBridgePort を先に握った**別プロジェクトのエディタ**へ"
            "繋がったまま緑になりうるため、確認できないまま先へ進めません"
        )
    expected = _expected_project_path()
    if expected is None:
        raise WrongBridgeTargetError(
            f"エディタ直結の接続（{host}:{port}）で、期待するプロジェクトを特定できません"
            f"（接続先は {reported!r} と答えています）。\n"
            "  UAPP_E2E_PROJECT_PATH に対象 Unity プロジェクトの絶対パスを設定するか、"
            "e2e-config.json のあるツリーから実行してください"
        )
    if _same_project(expected, str(reported)):
        return
    raise WrongBridgeTargetError(
        f"エディタ直結の接続（{host}:{port}）が、**別のプロジェクトのエディタ**に繋がっています。\n"
        f"  期待: {expected}\n"
        f"  接続先: {reported}\n"
        "  典型原因: 2 つのプロジェクトの editorBridgePort が同じ番号で、先に Play した側が"
        "ポートを握っている（後発は bind failed のまま待ち続ける）。\n"
        "  対処: プロジェクトごとに editorBridgePort を別番号にする"
    )


def _check_ios_target(info: dict[str, Any], host: str, port: int) -> None:
    """`UAPP_E2E_IOS=1` なのに iOS シミュレータ以外へ繋がっていたら明示的に失敗させる。

    エディタ直結ガード（`_check_editor_target`）と同じ約束: **明示宣言だけを根拠に検査する**。
    iOS シミュレータのアプリは**ホストのポート名前空間で直接 LISTEN する**ため、
    adb forward（デバイス）や editorBridgePort（エディタ）と同じ番号を選ぶと取り合いになる。
    宣言があるときだけ ping の `platform`（iOS プレイヤーは `IPhonePlayer`）を確かめ、
    違えば偽の緑になる前に止める（fail-closed。platform 欠落も通さない）。
    """
    if os.environ.get("UAPP_E2E_IOS") != "1":
        return
    platform = str(info.get("platform", ""))
    if platform != "IPhonePlayer":
        detail = f"platform={platform!r}" if platform else "ping の応答に platform がありません"
        raise WrongBridgeTargetError(
            f"iOS 向けの接続（{host}:{port}）なのに、"
            f"接続先が iOS プレイヤーではありません（{detail}）。\n"
            "  典型原因: 同じ番号を adb forward（Android 経路）やエディタ（editorBridgePort）が握っている。\n"
            "  実機の場合は USB トンネル（iproxy）の張り先が想定と違う可能性もある。\n"
            "  確認: lsof -nP -iTCP:<port> -sTCP:LISTEN で待受プロセスを見る\n"
            "  対処: e2e-config.json の iosSimulatorPort を devicePort / editorBridgePort /"
            "ホスト側 forward ポートのどれとも別番号にする"
        )
    # **bundle id まで照合する**（platform だけでは「同じポートを握る別の iOS アプリ」を
    # 識別できない。UAPP_E2E_IOS_BUNDLE_ID は run-ios-e2e.ps1 が e2e-config.json の package を
    # 渡す。未宣言なら従来どおり platform 検査のみ）
    expected = os.environ.get("UAPP_E2E_IOS_BUNDLE_ID")
    if expected:
        actual = str(info.get("app", ""))
        if actual != expected:
            raise WrongBridgeTargetError(
                f"iOS 向けの接続（{host}:{port}）ですが、接続先のアプリ"
                f"（app={actual!r}）が期待した bundle id（{expected!r}）と一致しません。"
                "同じ iosSimulatorPort を別プロジェクトの iOS アプリが握っている可能性があります"
            )


def _check_target_declarations() -> None:
    """接続先宣言の矛盾を接続前に止める（両方立っていると、どちらの検査も意図どおり働かない）。"""
    if os.environ.get("UAPP_E2E_EDITOR") == "1" and os.environ.get("UAPP_E2E_IOS") == "1":
        raise WrongBridgeTargetError(
            "UAPP_E2E_EDITOR=1 と UAPP_E2E_IOS=1 が同時に宣言されています。"
            "接続先の意図が判定できないため中断します — 使わない側の環境変数を外してください"
        )


class BridgeClient:
    def __init__(self, host: str = "127.0.0.1", port: int | None = None, timeout: float = 30.0):
        self.host = host
        self.port = resolve_port(port)
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._file = None
        self._next_id = 1

    # ------------------------------------------------------------ connection

    def connect(self, retries: int = 30, interval: float = 1.0) -> "BridgeClient":
        """アプリ起動直後を考慮してリトライしながら接続する。"""
        _check_target_declarations()
        last_error: Exception | None = None
        for _ in range(retries):
            try:
                self._sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
                self._file = self._sock.makefile("r", encoding="utf-8", newline="\n")
                info = self.ping()  # 疎通確認（結果は接続先の検証にも使う。往復は増やさない）
                _check_editor_target(info, self.host, self.port)
                _check_ios_target(info, self.host, self.port)
                return self
            except (OSError, BridgeError) as e:
                last_error = e
                self.close()
                time.sleep(interval)
        raise ConnectionError(
            f"E2EBridge ({self.host}:{self.port}) に接続できません。"
            f"アプリ（またはエディタ再生）の起動、デバイス接続なら adb forward を確認してください: {last_error}"
        )

    def close(self) -> None:
        for closable in (self._file, self._sock):
            try:
                if closable:
                    closable.close()
            except OSError:
                pass
        self._file = None
        self._sock = None

    def __enter__(self) -> "BridgeClient":
        return self.connect()

    def __exit__(self, *_exc) -> None:
        self.close()

    # --------------------------------------------------------------- protocol

    def call(self, cmd: str, **args: Any) -> Any:
        if self._sock is None:
            raise ConnectionError("not connected. call connect() first")
        request = {"id": self._next_id, "cmd": cmd, "args": args}
        self._next_id += 1
        self._sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
        line = self._file.readline()
        if not line:
            raise ConnectionError("bridge closed the connection")
        response = json.loads(line)
        if not response.get("ok"):
            error = response.get("error", {})
            raise BridgeError(error.get("code", "UNKNOWN"), error.get("message", ""))
        return response.get("result")

    # --------------------------------------------------------------- commands

    def ping(self) -> dict:
        return self.call("ping")

    def screenshot(self, path=None, max_width: int | None = None) -> bytes:
        """画面を PNG で撮る（アプリ自身が撮るのでプラットフォーム非依存）。

        **OS 層のキャプチャが使えないときの保険**であって上位互換ではない —
        写るのは Unity の描画だけで、WebView・ネイティブダイアログ・ソフトキーボードは欠ける。
        iOS 実機では OS 層の手段が版で入れ替わる（16 以前は idevicescreenshot、
        17 以降は XCUITest の OS レイヤーエージェント。後者は端末側で
        「設定 → デベロッパ → UI オートメーションを有効」が要る）ため、
        **どちらも使えない構成でだけこれが最後の手段になる**。
        Android・エディタ・iOS シミュレータでも同じ手段で撮れる。

        path を渡すと保存もする。max_width を指定すると縮小して転送量を抑える
        （実機は解像度が大きく、base64 が数 MB になる）。
        """
        args = {}
        if max_width:
            args["maxWidth"] = int(max_width)
        result = self.call("screenshot", **args)
        png = base64.b64decode(result["base64"])
        if path is not None:
            target = Path(path)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(png)
        return png

    def dump(self, scope: str = "ui", probe: str = "selectable", path: str | None = None) -> dict:
        args: dict[str, Any] = {"scope": scope, "probe": probe}
        if path:
            args["path"] = path
        return self.call("dump", **args)

    def resolve(self, path: str) -> dict:
        return self.call("resolve", path=path)

    def get(self, path: str, component: str, prop: str) -> Any:
        return self.call("get", path=path, component=component, property=prop)["value"]

    def pointer_down(self, pointer_id: int, x: float, y: float) -> dict:
        return self.call("pointer_down", pointerId=pointer_id, x=x, y=y)

    def pointer_move(self, pointer_id: int, x: float, y: float) -> dict:
        return self.call("pointer_move", pointerId=pointer_id, x=x, y=y)

    def pointer_up(self, pointer_id: int) -> dict:
        return self.call("pointer_up", pointerId=pointer_id)

    def pointer_reset(self) -> dict:
        return self.call("pointer_reset")

    # --- UI を経由しない入力（キー / マウス / ゲームパッド）------------------
    # hittable 判定は関係しない。アプリが InputAction で読んでいても
    # デバイスを直読みしていても、実入力と同じ経路で届く。
    # レガシー入力バックエンドのみの構成では INPUT_BACKEND_LEGACY で明示的に失敗する

    def key_down(self, key: str) -> dict:
        return self.call("key_down", key=key)

    def key_up(self, key: str) -> dict:
        return self.call("key_up", key=key)

    def mouse_move(self, x: float, y: float) -> dict:
        return self.call("mouse_move", x=x, y=y)

    def mouse_down(self, button: str = "left", x: float | None = None, y: float | None = None) -> dict:
        args: dict[str, Any] = {"button": button}
        if x is not None and y is not None:
            args.update(x=x, y=y)
        return self.call("mouse_down", **args)

    def mouse_up(self, button: str = "left") -> dict:
        return self.call("mouse_up", button=button)

    def mouse_scroll(self, dx: float = 0.0, dy: float = 0.0) -> dict:
        return self.call("mouse_scroll", dx=dx, dy=dy)

    def pad_button_down(self, button: str) -> dict:
        return self.call("pad_button_down", button=button)

    def pad_button_up(self, button: str) -> dict:
        return self.call("pad_button_up", button=button)

    def pad_stick(self, stick: str = "left", x: float = 0.0, y: float = 0.0) -> dict:
        return self.call("pad_stick", stick=stick, x=x, y=y)

    def input_reset(self) -> dict:
        """押しっぱなしを全部離す（テスト間で状態を持ち越さない）。"""
        return self.call("input_reset")

    def input_devices(self) -> dict:
        """接続中の入力デバイス一覧。**実機が刺さっているか**を確認するために使う。

        エディタ実行の PC には本物のキーボード・マウス・ゲームパッドが同時に居る。
        注入は専用の仮想デバイスへ行うが、人が実機を触れば `current` は奪われる。
        原因不明の不安定さにしないよう、`realGamepads` 等で最初から見えるようにしている。

        **仮想デバイスは種別ごとに「初回注入時」に生成される（遅延生成）。**
        つまり `key_down` / `mouse_move` / `pad_stick` を一度も呼んでいない種別は
        `devices` に出てこない。**これは実機に注入しているのではない**（注入先は常に仮想デバイス）。
        どの種別が生成済みかは `virtualDevices` を見る:

            {"virtualDevices": [{"kind": "mouse", "name": "E2EVirtualMouse", "created": false}, ...]}

        `devices` を名前で引くコードは、注入前だと KeyError になる（導入先で実際に踏まれた）。
        注入後に取り直すか、`virtualDevices` の `created` を見ること。
        """
        return self.call("input_devices")

    def ngui_event(self, path: str, event: str = "click") -> dict:
        """NGUI向けフレームワークレベルイベント送出（click | press | release）。

        レガシーInput構成のNGUIアプリ（Touchscreen注入が届かない）で使う。
        到達可能性は検証しないため、通常は Gestures.ngui_tap 経由で使うこと。
        """
        return self.call("ngui_event", path=path, event=event)



def wait_for_bridge(timeout: float = 60.0, host: str = "127.0.0.1",
                    port: int | None = None, interval: float = 1.0) -> BridgeClient:
    """ブリッジが応答するまで待って、接続済みクライアントを返す。

    **Play をまたぐテストの定番部品**（導入先要望）: エディタ直結では
    `unity cmd editor_stop` → `editor_play` のあと、ブリッジが再び待ち受けるまで
    数秒〜数十秒かかる。各プロジェクトが自前のポーリングを書かなくて済むよう、
    「タイムアウトまで接続を試し続ける」だけをここに置く。

        client = wait_for_bridge(timeout=60)   # ポートは e2e-config.json を自動解決

    接続できなければ ConnectionError（BridgeClient.connect と同じ内容）を投げる。
    """
    # 実時間の deadline で打ち切る（回数換算だと、接続だけ受理して ping に応答しない
    # 停止途中のリスナー相手に「1 試行 = ソケット timeout 30 秒」が積み上がり、
    # timeout=60 のつもりが 30 分級になりうる）。各試行のソケット timeout も残時間で抑える
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while True:
        # **最低 1 回は必ず試す**（timeout=0 は「即時プローブ 1 回」。ループ先頭で
        # 残時間切れを判定すると 0 や負値が一度も接続せずに失敗する — 再レビュー指摘）。
        # ソケット timeout は残時間で抑える（下限で丸めると短い timeout 指定を応答しない
        # リスナー相手に超過する。0.05 は「試行を成立させる最小値」で体感に影響しない。
        # 上限 10 秒は 1 接続が固まったまま全体を使い切るのを避けるため）
        remaining = max(deadline - time.monotonic(), 0.0)
        client = BridgeClient(host=host, port=port,
                              timeout=min(max(remaining, 0.05), 10.0))
        try:
            return client.connect(retries=1, interval=0)
        except ConnectionError as e:
            last_error = e
        if time.monotonic() >= deadline:
            break
        time.sleep(min(max(interval, 0.1), max(deadline - time.monotonic(), 0)))
    raise ConnectionError(
        f"E2EBridge が {timeout} 秒以内に応答しません: {last_error}"
    )
