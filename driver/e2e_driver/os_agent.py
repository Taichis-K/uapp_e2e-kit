"""iOS の OS レイヤーエージェント（XCUITest 常駐サーバー）のクライアント。

**E2EBridge の置き換えではなく補完**。ブリッジは Unity の中しか見えず、
外部ブラウザ・システムダイアログ・WebView・ソフトキーボードは `dump` にも `tap` にも
現れず、計装側のスクショにも写らない。このエージェントは XCUITest として
**アプリの外側**から OS を操作するので、その穴を埋める。
Android における `adb`（uiautomator 経由）に相当する。

**Unity の要素は見えない**（Unity は Metal のビュー 1 枚として現れ、アクセシビリティ
ツリーに UI が出ない）。だから要素指定の操作はブリッジ側（path・hittable 判定つき）を使い、
ここは**座標**で操作する。`tap_unity()` は dump の Unity 座標を正規化座標へ変換するので、
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
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_TIMEOUT = 30.0


class OsAgentError(RuntimeError):
    """エージェントとの通信・操作が失敗した。"""


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
        raise OsAgentError(f"{method} {path} が失敗（HTTP {e.code}）: {body}") from e
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
    大きさ（回転しない）なので、横画面の screen には使わない。
    """
    width, height = screen
    if width <= 0 or height <= 0:
        raise OsAgentError(f"画面サイズが不正です: {screen}")
    tap(x / width, 1.0 - (y / height), bundle_id=bundle_id)


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


def type_text(text: str, bundle_id: str) -> None:
    """**対象アプリを明示して**文字を送る（入力欄のタップは呼び出し側で行う）。

    XCUITest の `typeText` は「呼び出した要素かその子孫にキーボードフォーカスがあること」が
    前提なので、送り先のアプリを指定しないと入力は届かない。対象が前面にない場合はエラー。
    """
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


def stop(timeout: float = 10.0) -> None:
    """エージェントを終了させる。**失敗は無視**（後始末はスクリプト側でも行う）。"""
    try:
        _post("/stop", {}, timeout=timeout)
    except OsAgentError:
        pass
