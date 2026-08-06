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


def tap(x: float, y: float) -> None:
    """正規化座標（0〜1・左上原点）でタップする。**画面解像度に依存しない**。"""
    _post("/tap", {"x": float(x), "y": float(y)})


def tap_unity(x: float, y: float, screen: tuple[int, int]) -> None:
    """Unity スクリーン座標（左下原点・ピクセル）でタップする。

    dump / resolve が返す `center` をそのまま渡せる。**Y 軸の反転**と正規化をここで吸収する
    （`adb.input_tap_unity_coords` と同じ役割の iOS 版）。
    """
    width, height = screen
    if width <= 0 or height <= 0:
        raise OsAgentError(f"画面サイズが不正です: {screen}")
    tap(x / width, 1.0 - (y / height))


def swipe(x1: float, y1: float, x2: float, y2: float, duration: float = 0.2) -> None:
    """正規化座標でスワイプする。

    **待ち時間は duration から算出する** — 固定値にすると、長いスワイプで
    「クライアントは失敗したのに画面は動いている」状態になる。
    """
    _post("/swipe", {"x1": float(x1), "y1": float(y1),
                     "x2": float(x2), "y2": float(y2), "duration": float(duration)},
          timeout=DEFAULT_TIMEOUT + float(duration))


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
