"""iOS の OS レイヤーエージェント（XCUITest 常駐サーバー）のクライアント。

**E2EBridge の置き換えではなく補完**。ブリッジは Unity の中しか見えず、
外部ブラウザ・システムダイアログ・WebView・ソフトキーボードは `dump` にも `tap` にも
現れず、計装側のスクショにも写らない。このエージェントは XCUITest として
**アプリの外側**から OS を操作するので、その穴を埋める。
Android における `adb`（uiautomator 経由）に相当する。

**Unity の要素は見えない**（Unity は Metal のビュー 1 枚として現れ、アクセシビリティ
ツリーに UI が出ない）。Unity の要素はブリッジ側（path・hittable 判定つき）で扱い、
ここでは**座標**で操作する。**アクセシビリティの要素**（`find_elements` / `tap_element` / `type_into` …）は
Unity の外（WebView・Safari・システム UI・ネイティブのダイアログ）のためのもの（issue #85）。`tap_unity()` は dump の Unity 座標を正規化座標へ変換するので、
呼び出し側が解像度を意識せずに済む。

接続先は環境変数 `UAPP_E2E_OS_AGENT_URL`（例: `http://127.0.0.1:8200`）、
認証は `UAPP_E2E_OS_AGENT_TOKEN`。`run-ios-e2e.ps1 -OsAgent` が起動・トンネル・停止まで面倒を見る。

**トークンは「別個体へ繋いでいないこと」の確認にも使う** — 並行実行や古いトンネルの残骸が
同じポートを握っていると、別の端末を操作したまま緑になりうる。`status()` は
`authenticated` が真であることまで確かめる（トークン無しで動く残骸を弾く）。
"""
from __future__ import annotations

import json
import os
import re
import warnings
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_TIMEOUT = 30.0


class OsAgentError(RuntimeError):
    """エージェントとの通信・操作が失敗した。

    `http_status` と `body` はエージェントが HTTP のエラーを返したときの状態コードと本文（それ以外は None）。
    """

    def __init__(self, message: str, *, http_status: int | None = None, body: str | None = None):
        super().__init__(message)
        self.http_status = http_status
        self.body = body


def base_url() -> str | None:
    """エージェントの URL（未宣言なら None＝この経路を使わない）。"""
    url = os.environ.get("UAPP_E2E_OS_AGENT_URL")
    return url.rstrip("/") if url else None


def available() -> bool:
    """**宣言されているかどうかだけ**を見る（疎通は呼び出し時に判明する）。

    ブリッジ側のガード（`UAPP_E2E_EDITOR` / `UAPP_E2E_IOS`）と同じ約束で、
    明示的な宣言がある接続だけこの経路を使う。
    """
    return base_url() is not None


def _request(method: str, path: str, payload: dict | None = None,
             timeout: float = DEFAULT_TIMEOUT) -> tuple[bytes, str]:
    url = base_url()
    if not url:
        raise OsAgentError("UAPP_E2E_OS_AGENT_URL が未設定です（エージェント未起動）")
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(url + path, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    token = os.environ.get("UAPP_E2E_OS_AGENT_TOKEN")
    if token:
        request.add_header("X-Uapp-Token", token)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read(), response.headers.get_content_type()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise OsAgentError(f"{method} {path} が失敗（HTTP {e.code}）: {body}",
                           http_status=e.code, body=body) from e
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise OsAgentError(
            f"OS エージェント（{url}）へ接続できません: {e}. "
            "run-ios-e2e.ps1 -OsAgent で起動しているか、iproxy のトンネルを確認してください"
        ) from e


def _post(path: str, payload: dict, timeout: float = DEFAULT_TIMEOUT) -> dict:
    body, _ = _request("POST", path, payload, timeout)
    return json.loads(body) if body else {}


def status(timeout: float = 10.0) -> dict:
    """生存確認。`{"agent": ..., "platform": "iOS", "screen": {...}}`。"""
    body, _ = _request("GET", "/status", None, timeout)
    info = json.loads(body)
    # **接続先を確かめる**（同じポートを別のサーバーが握っていたら止める。
    # ブリッジの platform 検査と同じ趣旨で、黙って別物を操作しない）
    if info.get("agent", "").split("/")[0] != "uapp-os-agent":
        raise OsAgentError(
            f"接続先が uapp_e2e の OS エージェントではありません（{info!r}）。"
            "ポートを別のプロセスが握っている可能性があります"
        )
    # **トークンを使う設定なら、認証済みであることまで要求する**。
    # 認証なしで動いている個体は「自分が起動したものではない」（並行実行や古い残骸）
    if os.environ.get("UAPP_E2E_OS_AGENT_TOKEN") and not info.get("authenticated"):
        raise OsAgentError(
            "接続先のエージェントが認証されていません（自分が起動した個体ではない可能性）。"
            "並行実行や古い USB トンネルが同じポートを握っていないか確認してください"
        )
    return info


def screenshot(path=None, timeout: float = DEFAULT_TIMEOUT) -> bytes:
    """画面全体の PNG。**OS が合成した結果**なので WebView・ダイアログ・キーボードも写る。"""
    body, content_type = _request("GET", "/screenshot", None, timeout)
    if content_type != "image/png" or not body:
        raise OsAgentError(f"スクリーンショットを取得できません（content-type={content_type}）")
    if path is not None:
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body)
    return body


# bundleId に対応していると確かめた接続先（**押す前に**確かめた結果を「URL＋トークン」の組で覚える）
_BUNDLE_ID_SUPPORTED: set[tuple[str, str]] = set()


def _agent_key() -> tuple[str, str]:
    """確認結果を覚える単位。**トークンも含める** ― 同じ URL でもトークンが替われば別の起動なので確かめ直す
    （URL だけだと、繋ぎ替えた個体の版も認証も確かめずに押してしまう）。"""
    return base_url() or "", os.environ.get("UAPP_E2E_OS_AGENT_TOKEN") or ""


def _with_bundle_id(payload: dict, bundle_id: str | None) -> dict:
    """`bundle_id` を検査して payload に足す。**渡さなければ payload は従来と同一**。

    渡されたときは、**押す前に**エージェントが対応しているかを `/status` の `features` で確かめる。
    古いエージェントは `bundleId` を黙って無視して SpringBoard 基準で押し 200 を返すので、
    応答を見てからでは誤った位置をもう押し終えている（issue #80）。
    """
    if bundle_id is None:
        return payload
    if not isinstance(bundle_id, str) or not bundle_id:
        # 空文字を「渡さない」扱いにすると、設定漏れのときに黙って SpringBoard 基準に落ちる
        raise OsAgentError(f"bundle_id が空か文字列ではありません: {bundle_id!r}（省略するなら None）")
    # **確認は「URL＋トークン」ごとに 1 回だけ**。同じ URL・同じトークンのまま古い版へ入れ替わると
    # この確認は効かない（そのときは押したあとの `_check_base` が網になり、覚えた結果も捨てる）
    key = _agent_key()
    if key not in _BUNDLE_ID_SUPPORTED:
        features = status().get("features")
        # 文字列だと `in` が部分一致になるので、一覧であることまで確かめる
        if not isinstance(features, list) or "bundleId" not in features:
            raise OsAgentError(
                "接続先のエージェントが bundle_id（アプリ基準の座標）に対応していません"
                f"（/status の features={features!r}）。押していません。"
                "エージェントが古い版の可能性があります（run-ios-e2e -OsAgent ならキットの更新で次の実行から新しくなる。"
                "docs/09-ios16-osagent.md の手組みは手順 1 からやり直す）"
            )
        _BUNDLE_ID_SUPPORTED.add(key)
    return {**payload, "bundleId": bundle_id}


def _check_base(response: dict, bundle_id: str | None, path: str) -> None:
    """応答の `base` が送った bundle_id と一致するかを確かめる（**二重の安全**）。

    押す前の `features` の確認が主で、こちらは同じ URL のエージェントが別の版へ入れ替わった場合の網。
    `base` は送った綴りのエコーなので、**大小文字を区別して**照合する。
    """
    if bundle_id is None:
        return
    if response.get("base") != bundle_id:
        # 覚えていた「対応している」は当てにならないので捨てる（次の呼び出しで確かめ直す）
        _BUNDLE_ID_SUPPORTED.discard(_agent_key())
        raise OsAgentError(
            f"{path} の応答の base が送った bundle_id と一致しません"
            f"（送った: {bundle_id!r} / 応答: {response.get('base')!r}）。"
            "エージェントが bundle_id に対応していない版の可能性があります（再ビルド）"
        )


def tap(x: float, y: float, bundle_id: str | None = None) -> None:
    """正規化座標（0〜1・左上原点）でタップする。**画面解像度に依存しない**。

    **既定（bundle_id なし）は SpringBoard の画面が基準**（iPhone では回転しない＝縦。iPad は未実測）。システムダイアログ・
    ホーム画面を押すときはこちら。
    **bundle_id を渡すとそのアプリの画面が基準**になる。**横画面のアプリはこちらでないと当たらない**
    （issue #80）。**外部ブラウザなど別のアプリでも、横画面ならそのアプリの bundle id を渡す**
    （横画面の Safari は SpringBoard 基準では外れ、`com.apple.mobilesafari` 基準なら当たった。シミュレータで実測）。そのアプリが前面に無ければエージェントが拒否する（HTTP 409 → OsAgentError）。
    """
    payload = _with_bundle_id({"x": float(x), "y": float(y)}, bundle_id)
    _check_base(_post("/tap", payload), bundle_id, "/tap")


def tap_unity(x: float, y: float, screen: tuple[int, int], bundle_id: str | None = None) -> None:
    """Unity スクリーン座標（左下原点・ピクセル）でタップする。

    dump / resolve が返す `center` をそのまま渡せる。**Y 軸の反転**と正規化をここで吸収する
    （`adb.input_tap_unity_coords` と同じ役割の iOS 版）。

    **横画面のアプリでは bundle_id を渡し、screen にはアプリ側の画面サイズ**（Unity の
    `Screen.width`・`Screen.height`＝横長の値）を渡す。`status()` の `screen` は SpringBoard の
    大きさ（iPhone では回転しない。iPad は未実測）なので、横画面の screen には使わない。
    """
    width, height = screen
    if width <= 0 or height <= 0:
        raise OsAgentError(f"画面サイズが不正です: {screen}")
    tap(x / width, 1.0 - (y / height), bundle_id=bundle_id)


def _normalize_unity(x: float, y: float, screen: tuple[int, int]) -> tuple[float, float]:
    """Unity の座標（左下原点・ピクセル）を正規化座標（左上原点）へ（`tap_unity` と同じ変換）。"""
    width, height = screen
    if width <= 0 or height <= 0:
        raise OsAgentError(f"画面サイズが不正です: {screen}")
    return x / width, 1.0 - (y / height)


def swipe(x1: float, y1: float, x2: float, y2: float, duration: float = 0.2,
          bundle_id: str | None = None) -> None:
    """正規化座標でスワイプする。基準の選び方は `tap` と同じ（横画面のアプリは bundle_id を渡す）。

    **待ち時間は duration から算出する** — 固定値にすると、長いスワイプで
    「クライアントは失敗したのに画面は動いている」状態になる。
    """
    payload = _with_bundle_id({"x1": float(x1), "y1": float(y1),
                               "x2": float(x2), "y2": float(y2), "duration": float(duration)}, bundle_id)
    _check_base(_post("/swipe", payload, timeout=DEFAULT_TIMEOUT + float(duration)), bundle_id, "/swipe")


def swipe_unity(x1: float, y1: float, x2: float, y2: float, screen: tuple[int, int],
                duration: float = 0.2, bundle_id: str | None = None) -> None:
    """Unity スクリーン座標（左下原点・ピクセル）でスワイプする。

    `tap_unity` の swipe 版。dump / resolve が返す `center` をそのまま渡せる。
    **Y 軸の反転**と正規化をここで吸収する。

    これが無いと呼び手が毎回同じ換算を手で書くことになる（導入先が実際にそうしていた。
    2026-09-10 の実機検証で `ScrollRect` を動かすのに使われた）。
    横画面のアプリでは `tap_unity` と同じく bundle_id とアプリ側の画面サイズを渡す。
    """
    width, height = screen
    if width <= 0 or height <= 0:
        raise OsAgentError(f"画面サイズが不正です: {screen}")
    swipe(x1 / width, 1.0 - (y1 / height), x2 / width, 1.0 - (y2 / height), duration=duration,
          bundle_id=bundle_id)


# typeFocusCheck を持たない（古い）エージェントへの案内を出した接続先（URL＋トークン）
_TYPE_FOCUS_WARNED: set[tuple[str, str]] = set()


def type_text(text: str, bundle_id: str) -> None:
    """**対象アプリを明示して**文字を送る（入力欄のタップは呼び出し側で行う）。

    XCUITest の `typeText` は「呼び出した要素かその子孫にキーボードフォーカスがあること」が
    前提なので、送り先のアプリを指定しないと入力は届かない。対象が前面にない場合はエラー。

    **フォーカスを持つ要素が見えなければ 409**（`OsAgentError.http_status`）。本文の `keyboardVisible` が真なら
    「キーボードは出ているがフォーカスの要素がアクセシビリティに見えない」（Unity の入力欄をシミュレータで押したとき。
    XCUITest の typeText では入らない）、偽なら「先に入力欄を押す」。以前は見ずに送り、200 のあとエージェントごと
    終了した（issue #81）。**この確認を持たない古いエージェント**（features に typeFocusCheck が無い）では、
    フォーカスが無いまま送ると今もエージェントが終了するので、最初の呼び出しで警告する。
    """
    key = _agent_key()
    if key not in _TYPE_FOCUS_WARNED:
        try:
            features = status().get("features")
            _TYPE_FOCUS_WARNED.add(key)      # 確かめられたときだけ覚える（失敗したら次の呼び出しでまた確かめる）
        except OsAgentError:
            features = None
        if isinstance(features, list) and "typeFocusCheck" not in features:
            warnings.warn("接続先のエージェントはフォーカスの確認（typeFocusCheck）を持たない古い版です。"
                          "フォーカスが無いまま type_text を送るとエージェントが終了します（作り直しは run-ios-e2e -OsAgent なら自動、"
                          "docs/09-ios16-osagent.md の手組みは手順 1 から）")
    _post("/type", {"text": text, "bundleId": bundle_id})


def handle_alert(button: str | None = None, timeout: float = 5.0) -> dict:
    """システムアラートのボタンを押す（button 省略で先頭）。無ければ OsAgentError。"""
    payload: dict = {"timeout": timeout}
    if button is not None:
        payload["button"] = button
    return _post("/alert", payload, timeout=timeout + DEFAULT_TIMEOUT)


def activate(bundle_id: str) -> None:
    """**実行中の**アプリを前面へ出す（外部ブラウザ等から戻るのに使う）。

    `launch()` と違い**動いているアプリを終了させない**ので、ブリッジ接続が保たれる。
    ただし `activate()` 自体は**未起動なら起動してしまう** API なので、エージェント側で
    未起動を拒否している（黙って起動すると、クラッシュ等で状態が失われたことを隠すため）。
    """
    _post("/activate", {"bundleId": bundle_id})


# `/orientation` が受け付ける向き。名前は iOS の `UIDeviceOrientation` の case 名のまま（大小文字を区別）。
# アプリ側の向きの名前（`UIInterfaceOrientation` や Unity の `ScreenOrientation`）とは左右の名前が一致するとは限らない
ORIENTATIONS = ("portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight")


def rotate(orientation: str) -> None:
    """**端末の向き**を変える（XCUITest の `XCUIDevice.shared.orientation`。issue #83）。

    **アプリが回ったことは保証しない** ― 回るのはアプリがその向きに対応している場合だけで、
    エージェントにはアプリの向きが分からない。効果はアプリ側で確かめ、**縦横が変わるまで待つ**（更新は後のフレームになりうる）
    （Unity なら ping の `screen` の幅と高さ。名前で突き合わせない）。
    回したあと横画面のアプリを押すときは `bundle_id` を渡し、新しい画面サイズを使う。
    テストで回したら、終わりに `rotate("portrait")` で戻す（**エージェントを止めても向きは残る**。シミュレータと実機で実測）。

    応答の向き（書き込んだあとに読み直した値）が送った名前と違えば `OsAgentError`。
    """
    if not isinstance(orientation, str) or orientation not in ORIENTATIONS:
        raise OsAgentError(f"orientation は {ORIENTATIONS} のどれかを指定してください（大小文字を区別）: {orientation!r}")
    response = _post_new("/orientation", {"orientation": orientation}, "向きの変更（/orientation）", "端末は回していません。")
    actual = response.get("orientation")
    if actual != orientation:
        raise OsAgentError(
            f"/orientation の応答の向きが送った名前と一致しません（送った: {orientation!r} / 読み直した: {actual!r}）。"
            "この環境では端末の向きの書き込みが効いていない可能性があります"
        )


def _post_new(path: str, payload: dict, what: str, consequence: str = "何もしていません。",
              timeout: float = DEFAULT_TIMEOUT) -> dict:
    """新しい操作を送る。**送る前に /status を往復しない**（古い版は 404 で何も起きないため）。

    古いエージェントはハンドラの default が `unknown:` で始まる本文の 404 を返す。それだけを「古い版」の案内に読み替え、
    それ以外の 404（要素が無い・同じポートを別のサーバーが握っている等）はそのまま出す。
    """
    try:
        return _post(path, payload, timeout=timeout)
    except OsAgentError as e:
        if e.http_status == 404 and _error_text(e.body or "").startswith("unknown:"):
            raise OsAgentError(
                f"接続先のエージェントが{what}に対応していません。{consequence}"
                "エージェントが古い版の可能性があります（run-ios-e2e -OsAgent ならキットの更新で次の実行から新しくなる。"
                "docs/09-ios16-osagent.md の手組みは手順 1 からやり直す）",
                http_status=404, body=e.body,
            ) from e
        raise


def _error_text(body: str) -> str:
    """エラー応答の本文から `error` を取り出す（JSON でなければ空文字）。"""
    try:
        value = json.loads(body).get("error", "")
    except (ValueError, AttributeError):
        return ""
    return value if isinstance(value, str) else ""

# ------------------------------------------------------------------ issue #85: アプリ・要素・ジェスチャ・端末

# 要素の種類・ボタン・待つ状態の名前（エージェントと同じ一覧。大小文字を区別）
ELEMENT_TYPES = ("any", "button", "staticText", "textField", "secureTextField", "textView", "searchField", "link",
                 "image", "cell", "switch", "slider", "alert", "webView", "keyboard", "key", "icon", "other")
BUTTONS = ("home", "volumeUp", "volumeDown")
WAIT_STATES = ("exists", "gone", "hittable")
_MAX_ELEMENT_TIMEOUT = 30.0


def _require_bundle_id(bundle_id) -> str:
    if not isinstance(bundle_id, str) or not bundle_id:
        raise OsAgentError(f"bundle_id が空か文字列ではありません: {bundle_id!r}")
    return bundle_id


def app_state(bundle_id: str) -> dict:
    """アプリの状態（`{"state": <数>, "stateName": "runningForeground" …}`）。Android の `current_focus` の代わりに「何が前面か」を確かめる。"""
    return _post_new("/app/state", {"bundleId": _require_bundle_id(bundle_id)}, "アプリの状態の取得（/app/state）")


def launch_app(bundle_id: str, arguments: list[str] | None = None, environment: dict[str, str] | None = None) -> dict:
    """アプリを起動する。**動いていれば終了してから起動し直す**（XCUITest の仕様）。

    Unity アプリを起動し直すと**ブリッジの接続は切れる**ので、`wait_for_bridge` で繋ぎ直し、`device_log.clear()` し直す。
    ブリッジのポートは `environment={"UAPP_E2E_BRIDGE_PORT": "<アプリ側のポート>"}` で渡す（渡さないと既定の 13333）。
    アプリ側のポートは e2e-config.json の `iosSimulatorPort`（`run-ios-e2e` は `UAPP_E2E_IOS_APP_PORT` で渡す）。
    **実機では pytest の `UAPP_E2E_BRIDGE_PORT` はホスト側（iproxy の入口）なので、それを渡してはいけない**。
    `arguments` は Unity の managed 側から見えないので、Unity への受け渡しは `environment` を使う。
    起動に失敗するとエージェントが止まりうる（XCUITest がテストを止める）。
    """
    payload: dict = {"bundleId": _require_bundle_id(bundle_id)}
    if arguments is not None:
        if not isinstance(arguments, list) or not all(isinstance(a, str) for a in arguments):
            raise OsAgentError("arguments は文字列のリストで指定してください")
        payload["arguments"] = arguments
    if environment is not None:
        if not isinstance(environment, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in environment.items()):
            raise OsAgentError("environment は文字列から文字列への辞書で指定してください")
        payload["environment"] = environment
    return _post_new("/app/launch", payload, "アプリの起動（/app/launch）", timeout=90.0)


def terminate_app(bundle_id: str) -> dict:
    """アプリを終了する（未起動でもエラーにしない）。"""
    return _post_new("/app/terminate", {"bundleId": _require_bundle_id(bundle_id)}, "アプリの終了（/app/terminate）", timeout=60.0)


def _query(bundle_id, identifier, label, value, label_contains, type) -> dict:  # noqa: A002 (エージェントの引数名)
    q: dict = {}
    if bundle_id is not None:
        q["bundleId"] = _require_bundle_id(bundle_id)
    for key, v in (("identifier", identifier), ("label", label), ("value", value), ("labelContains", label_contains)):
        if v is not None:
            if not isinstance(v, str) or not v:
                raise OsAgentError(f"{key} は空でない文字列で指定してください: {v!r}")
            q[key] = v
    if type is not None:
        if type not in ELEMENT_TYPES:
            raise OsAgentError(f"type は {ELEMENT_TYPES} のどれかを指定してください（大小文字を区別）: {type!r}")
        q["type"] = type
    if len([k for k in q if k != "bundleId"]) == 0:
        raise OsAgentError("identifier / label / value / label_contains / type のどれかが要ります（全要素は accessibility_tree）")
    return q


def _timeout(timeout: float) -> float:
    if not isinstance(timeout, (int, float)) or timeout < 0 or timeout > _MAX_ELEMENT_TIMEOUT:
        raise OsAgentError(f"timeout は 0〜{_MAX_ELEMENT_TIMEOUT} 秒で指定してください: {timeout!r}")
    return float(timeout)


def find_elements(*, bundle_id: str | None = None, identifier: str | None = None, label: str | None = None,
                  value: str | None = None, label_contains: str | None = None, type: str | None = None,  # noqa: A002
                  limit: int = 50) -> dict:
    """アクセシビリティの要素を探す（`{"count": <一致数>, "elements": [...]}`）。**Unity の UI は出ない**。

    `bundle_id` を省くと SpringBoard（ホーム画面・システムの UI）。各要素の `center` はそのアプリの画面の正規化座標で、
    `tap(…, bundle_id=…)` に同じ `bundle_id` で渡せる。**押せるか（hittable）は返さない**（`tap_element` が判断する）。
    並び順と `tap_element` の `index` は一致するとは限らないので、押すときは一意に決まる指定を使う。
    """
    payload = _query(bundle_id, identifier, label, value, label_contains, type)
    payload["limit"] = int(limit)
    return _post_new("/elements", payload, "要素の検索（/elements）")


def tap_element(*, bundle_id: str | None = None, identifier: str | None = None, label: str | None = None,
                value: str | None = None, label_contains: str | None = None, type: str | None = None,  # noqa: A002
                index: int = 0, timeout: float = 5.0) -> dict:
    """要素が現れるのを待って押す。現れなければ 404、**存在するが押せない（画面外・覆われている）なら 409**（`OsAgentError.http_status`）。"""
    payload = _query(bundle_id, identifier, label, value, label_contains, type)
    payload.update({"index": int(index), "timeout": _timeout(timeout)})
    return _post_new("/element/tap", payload, "要素を押す操作（/element/tap）", timeout=timeout + DEFAULT_TIMEOUT)


def wait_element(*, state: str = "exists", bundle_id: str | None = None, identifier: str | None = None,
                 label: str | None = None, value: str | None = None, label_contains: str | None = None,
                 type: str | None = None, index: int = 0, timeout: float = 5.0) -> dict:  # noqa: A002
    """要素が `exists` / `gone` / `hittable` になるまで待つ（時間切れは 408 の `OsAgentError`）。"""
    if state not in WAIT_STATES:
        raise OsAgentError(f"state は {WAIT_STATES} のどれかを指定してください（大小文字を区別）: {state!r}")
    payload = _query(bundle_id, identifier, label, value, label_contains, type)
    payload.update({"state": state, "index": int(index), "timeout": _timeout(timeout)})
    return _post_new("/element/wait", payload, "要素を待つ操作（/element/wait）", timeout=timeout + DEFAULT_TIMEOUT)


def type_into(text: str, *, clear: bool = False, bundle_id: str | None = None, identifier: str | None = None,
              label: str | None = None, value: str | None = None, label_contains: str | None = None,
              type: str | None = None, index: int = 0, timeout: float = 5.0) -> dict:  # noqa: A002
    """要素を押してフォーカスを当て、文字を入れる。`clear=True` は既存の値を消してから入れる。

    **消し切れなければ 409 で入力しない**（カーソル位置・消去ボタン・伏せ字のせいで値が混ざるのを防ぐ）。
    **消したあとの値がプレースホルダーと同じでも 409**（空欄なのか、残りがたまたま同じ文字列なのか判別できない）。
    プレースホルダーのある欄では空になると値がプレースホルダーとして読めることがあるので、**空欄に入れるときは `clear` を付けない**。
    """
    if not isinstance(text, str):
        raise OsAgentError(f"text は文字列で指定してください: {text!r}")
    payload = _query(bundle_id, identifier, label, value, label_contains, type)
    payload.update({"text": text, "clear": bool(clear), "index": int(index), "timeout": _timeout(timeout)})
    return _post_new("/element/type", payload, "要素への文字入力（/element/type）", timeout=timeout + DEFAULT_TIMEOUT)


def accessibility_tree(bundle_id: str | None = None) -> str:
    """アクセシビリティツリーを丸ごと（`debugDescription`）。人と AI が読むデバッグ用で、形式は Apple の実装依存（機械で解析しない）。"""
    payload = {} if bundle_id is None else {"bundleId": _require_bundle_id(bundle_id)}
    try:
        body, _ = _request("POST", "/tree", payload)
    except OsAgentError as e:
        if e.http_status == 404 and _error_text(e.body or "").startswith("unknown:"):
            raise OsAgentError("接続先のエージェントがツリーの取得（/tree）に対応していません。エージェントが古い版の可能性があります",
                               http_status=404, body=e.body) from e
        raise
    return body.decode("utf-8", errors="replace")


def double_tap(x: float, y: float, bundle_id: str | None = None) -> None:
    """正規化座標でダブルタップ（基準と前面確認は `tap` と同じ。横画面のアプリは `bundle_id` を渡す）。"""
    payload = _with_bundle_id({"x": x, "y": y}, bundle_id)
    _check_base(_post_new("/doubletap", payload, "ダブルタップ（/doubletap）"), bundle_id, "/doubletap")


def double_tap_unity(x: float, y: float, screen: tuple[int, int], bundle_id: str | None = None) -> None:
    """Unity の座標（左下原点）でダブルタップ。"""
    nx, ny = _normalize_unity(x, y, screen)
    double_tap(nx, ny, bundle_id=bundle_id)


def long_press(x: float, y: float, duration: float = 1.0, bundle_id: str | None = None) -> None:
    """正規化座標で長押し（`duration` は 0 より大きく 10 秒以下）。"""
    if not isinstance(duration, (int, float)) or not 0 < duration <= 10:
        raise OsAgentError(f"duration は 0 より大きく 10 以下で指定してください: {duration!r}")
    payload = _with_bundle_id({"x": x, "y": y, "duration": float(duration)}, bundle_id)
    _check_base(_post_new("/longpress", payload, "長押し（/longpress）", timeout=duration + DEFAULT_TIMEOUT),
                bundle_id, "/longpress")


def long_press_unity(x: float, y: float, screen: tuple[int, int], duration: float = 1.0,
                     bundle_id: str | None = None) -> None:
    """Unity の座標（左下原点）で長押し。"""
    nx, ny = _normalize_unity(x, y, screen)
    long_press(nx, ny, duration=duration, bundle_id=bundle_id)


def pinch(bundle_id: str, scale: float, velocity: float | None = None) -> dict:
    """アプリの要素に対してピンチ（`scale` は 0.1〜10。`velocity` を省くと scale に合わせる）。座標指定のピンチは XCUITest に無い。"""
    if not isinstance(scale, (int, float)) or not 0.1 <= scale <= 10:
        raise OsAgentError(f"scale は 0.1〜10 で指定してください: {scale!r}")
    payload: dict = {"bundleId": _require_bundle_id(bundle_id), "scale": float(scale)}
    if velocity is not None:
        payload["velocity"] = float(velocity)
    return _post_new("/pinch", payload, "ピンチ（/pinch）")


def press_button(name: str) -> dict:
    """端末のボタン（`home` / `volumeUp` / `volumeDown`）。音量はシミュレータでは 400。"""
    if name not in BUTTONS:
        raise OsAgentError(f"button は {BUTTONS} のどれかを指定してください（大小文字を区別）: {name!r}")
    return _post_new("/press", {"button": name}, "ボタンを押す操作（/press）")


def open_url(url: str) -> dict:
    """URL・ディープリンクを開く（iOS 16.4 以降。独自スキームは初回に「開きますか」で戻らないことがある）。"""
    if not isinstance(url, str) or not re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", url):
        raise OsAgentError(f"url はスキームつきで指定してください（例: https://… / myapp://…）: {url!r}")
    return _post_new("/open-url", {"url": url}, "URL を開く操作（/open-url）")



def stop(timeout: float = 10.0) -> None:
    """エージェントを終了させる。**失敗は無視**（後始末はスクリプト側でも行う）。"""
    try:
        _post("/stop", {}, timeout=timeout)
    except OsAgentError:
        pass
