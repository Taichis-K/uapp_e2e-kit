"""adb ラッパー。エミュレーター操作・ログ監視・スクリーンショット取得。

logcat の Unity 例外監視は E2E の標準アサーションとして使う
（マルチタッチ中の NullReference 等、UI 状態に現れない破綻を捕まえる）。
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

import os

from .client import _env_port

# ホスト側ポート（run-e2e.ps1 が -HostPort / config/local.json から環境変数で渡す）。
# 無効な環境変数値は警告して既定へ（import 時の ValueError 死や、値域外を
# BridgeClient へ明示引数として渡してしまう事故を防ぐ。検証は client._parse_port と共通）
BRIDGE_PORT = _env_port("UAPP_E2E_BRIDGE_PORT") or 13333
# デバイス内でアプリが待ち受けるポート（e2e-config.json の devicePort。run-e2e.ps1 が環境変数で渡す。
# 同一デバイスに計装アプリが複数ある場合はアプリごとに別ポート）。
DEVICE_BRIDGE_PORT = _env_port("UAPP_E2E_DEVICE_PORT") or 13333
# 複数デバイス同時運用時の対象指定（run-e2e.ps1 の -DeviceSerial → 環境変数）。
# 未指定なら adb の既定（接続デバイスが1台のときのみ有効）。
DEVICE_SERIAL = os.environ.get("UAPP_E2E_DEVICE_SERIAL")
# 対象アプリは run-e2e.ps1 が -Project に応じて環境変数で指定する
PACKAGE = os.environ.get("UAPP_E2E_PACKAGE", "com.uapp.e2esample")
MAIN_ACTIVITY = "com.unity3d.player.UnityPlayerActivity"

_EXCEPTION_PATTERN = re.compile(
    r"(Exception|Error:|CRASH|Force finishing|ANR in)", re.IGNORECASE
)


class AdbNotFoundError(RuntimeError):
    """adb が使えない恒久エラー（未インストール / エディタ直結モード）。リトライしても回復しない。"""


_ADB_MISSING = ("adb が見つかりません。Android SDK Platform-Tools を導入して PATH に追加してください"
                "（エディタ再生のみで使う場合は adb 不要: UAPP_E2E_EDITOR=1 で pytest、"
                "または BridgeClient 直結）")

_EDITOR_MODE = ("UAPP_E2E_EDITOR=1（エディタ直結モード）のため adb は使いません。"
                "この操作は デバイス前提です — エディタ実行から対象テストを除外（-k / marker）するか、"
                "UAPP_E2E_EDITOR を外してデバイスで実行してください")


def _adb_base() -> list[str]:
    return ["adb", "-s", DEVICE_SERIAL] if DEVICE_SERIAL else ["adb"]


def _check_adb_available() -> None:
    """エディタ直結モードでの adb 使用を明示的に失敗させる。

    ガードが無いと、端末が接続されていた場合に「エディタをテストしたつもりで
    端末側の logcat / 画面を検証して偽の成功になる」事故が起きる。
    （ジャーニー記録の screencap は Exception を握って続行するため影響しない）
    """
    if os.environ.get("UAPP_E2E_EDITOR") == "1":
        raise AdbNotFoundError(_EDITOR_MODE)


def _run(*args: str, check: bool = True) -> str:
    _check_adb_available()
    try:
        result = subprocess.run(
            [*_adb_base(), *args], capture_output=True, text=True, encoding="utf-8", errors="replace"
        )
    except FileNotFoundError as e:
        raise AdbNotFoundError(_ADB_MISSING) from e
    if check and result.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def forward(host_port: int = BRIDGE_PORT, device_port: int = DEVICE_BRIDGE_PORT) -> None:
    _run("forward", f"tcp:{host_port}", f"tcp:{device_port}")


def install(apk_path: str) -> None:
    _run("install", "-r", "-g", apk_path)


def launch(package: str = PACKAGE, activity: str = MAIN_ACTIVITY) -> None:
    _run("shell", "am", "start", "-n", f"{package}/{activity}")


def force_stop(package: str = PACKAGE) -> None:
    _run("shell", "am", "force-stop", package)


def uninstall(package: str = PACKAGE) -> None:
    """アプリを完全削除する（クリーンインストール検証用）。未導入でもエラーにしない。"""
    _run("uninstall", package, check=False)


def is_installed(package: str = PACKAGE) -> bool:
    return package in _run("shell", "pm", "list", "packages", package, check=False)


def current_focus() -> str:
    """現在フォアグラウンドのウィンドウ/アクティビティ（アプリ遷移の判定用）。"""
    return _run("shell", "dumpsys", "window", check=False)


# --------------------------------------------------------------- ネイティブUI操作
# Unity の外（Chrome の認証ページ、Android のアプリ選択ダイアログ等）は E2EBridge では
# 操作できない。ここは uiautomator のアクセシビリティツリーを使い、**座標ではなくテキスト等の
# 要素条件で**タップする（解像度・レイアウト変化に強く、クリーンインストールの反復に耐える）。
# 注意: Unity 本体の画面は単一 SurfaceView なので uiautomator からは中身が見えない（Bridge を使う）。

_BOUNDS_RE = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


def ui_hierarchy() -> str:
    """uiautomator でネイティブ UI 階層 XML を取得する。"""
    out = _run("shell", "uiautomator", "dump", "/sdcard/uidump.xml", check=False)
    if "dumped to" not in out and "UI hierchary" not in out:
        # 稀に stdout に直接 XML を吐く端末があるためフォールバック
        if out.strip().startswith("<?xml") or "<hierarchy" in out:
            return out
    return _run("shell", "cat", "/sdcard/uidump.xml")


def _iter_nodes(xml: str):
    """uiautomator XML の各 node を (属性dict) で列挙する（依存を増やさない簡易パーサ）。"""
    for m in re.finditer(r"<node\b([^>]*?)/?>", xml):
        attrs = dict(re.findall(r'(\w[\w-]*)="([^"]*)"', m.group(1)))
        yield attrs


def find_ui_node(*, text: str | None = None, contains: bool = False,
                 resource_id: str | None = None, desc: str | None = None,
                 class_name: str | None = None, xml: str | None = None) -> dict | None:
    """条件に一致する最初のノードを返す（bounds から center を計算して付与）。無ければ None。

    条件: text（contains=True で部分一致）/ resource_id / desc(content-desc部分一致) / class_name。
    """
    xml = xml if xml is not None else ui_hierarchy()
    for attrs in _iter_nodes(xml):
        if text is not None:
            t = attrs.get("text", "")
            if not (text in t if contains else t == text):
                continue
        if resource_id is not None and attrs.get("resource-id") != resource_id:
            continue
        if desc is not None and desc not in attrs.get("content-desc", ""):
            continue
        if class_name is not None and attrs.get("class") != class_name:
            continue
        m = _BOUNDS_RE.search(attrs.get("bounds", ""))
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        attrs["center"] = ((x1 + x2) // 2, (y1 + y2) // 2)
        return attrs
    return None


def ui_wait(*, timeout: float = 20.0, interval: float = 1.0, **cond) -> dict:
    """条件に一致するネイティブUIノードが現れるまで待つ（find_ui_node の引数）。"""
    import time
    deadline = time.monotonic() + timeout
    last_xml = ""
    while time.monotonic() < deadline:
        last_xml = ui_hierarchy()
        node = find_ui_node(xml=last_xml, **cond)
        if node:
            return node
        time.sleep(interval)
    raise TimeoutError(f"ネイティブUI要素が現れません: {cond}\n---\n{last_xml[:2000]}")


def ui_tap(*, timeout: float = 20.0, **cond) -> dict:
    """テキスト等の条件でネイティブUI要素をタップする（座標非依存）。"""
    node = ui_wait(timeout=timeout, **cond)
    x, y = node["center"]
    _run("shell", "input", "tap", str(x), str(y))
    return node


def ui_type(text: str, *, clear: bool = False, field_cond: dict | None = None) -> None:
    """ネイティブ入力欄に文字を入れる。field_cond 指定時はまずその欄をタップしてフォーカスする。

    input text は空白を %s に、記号を一部要エスケープするため ASCII 前提（アカウント名等）。
    """
    if field_cond:
        ui_tap(**field_cond)
    if clear:
        # 全選択して削除（既存値クリア）
        _run("shell", "input", "keyevent", "KEYCODE_MOVE_END")
        for _ in range(64):
            _run("shell", "input", "keyevent", "KEYCODE_DEL")
    _run("shell", "input", "text", text.replace(" ", "%s"))


def clear_logcat() -> None:
    _run("logcat", "-c")


def unity_log() -> str:
    """バッファに溜まった Unity タグのログを取得する（-d: 非ブロッキング）。"""
    return _run("logcat", "-d", "-s", "Unity:*")


def unity_exceptions() -> list[str]:
    """Unity ログから例外・クラッシュ痕跡の行を抽出する。"""
    return [line for line in unity_log().splitlines() if _EXCEPTION_PATTERN.search(line)]


def screencap(local_path: str | Path) -> Path:
    """スクリーンショットをローカルに保存する。AI はこの画像を読んで描画検証する。"""
    local = Path(local_path)
    local.parent.mkdir(parents=True, exist_ok=True)
    _check_adb_available()
    try:
        png = subprocess.run(
            [*_adb_base(), "exec-out", "screencap", "-p"], capture_output=True
        )
    except FileNotFoundError as e:
        raise AdbNotFoundError(_ADB_MISSING) from e
    if png.returncode != 0:
        raise RuntimeError(f"screencap failed: {png.stderr.decode(errors='replace')}")
    local.write_bytes(png.stdout)
    return local


def wm_size() -> tuple[int, int]:
    """デバイスの物理解像度 (width, height)。adb input 座標変換用。"""
    out = _run("shell", "wm", "size")
    match = re.search(r"(\d+)x(\d+)", out)
    if not match:
        raise RuntimeError(f"unexpected wm size output: {out}")
    return int(match.group(1)), int(match.group(2))


def display_rotation() -> int:
    """現在の画面回転（0=縦, 1=横(左), 2=逆縦, 3=横(右)）。取得できなければ0。"""
    out = _run("shell", "dumpsys", "window", check=False)
    match = re.search(r"(?:mRotation|rotation)[=\s]+(?:ROTATION_)?(\d+)", out)
    if not match:
        return 0
    value = int(match.group(1))
    return {0: 0, 90: 1, 180: 2, 270: 3}.get(value, value if value in (0, 1, 2, 3) else 0)


def input_tap_unity_coords(unity_x: float, unity_y: float, unity_screen: tuple[int, int]) -> None:
    """Unity スクリーン座標(左下原点)を Android 座標(左上原点)へ変換して本物のタップを打つ。

    アプリ内注入より忠実（Android→Unity の入力境界を通る）。単点スモーク用。
    横画面（回転90/270）では表示座標系の幅・高さが入れ替わるため回転を考慮する。
    レンダリング解像度と物理解像度が異なる場合はスケールも吸収する。
    """
    physical_w, physical_h = wm_size()  # 回転に関わらず縦持ち基準で返る
    if display_rotation() in (1, 3):
        physical_w, physical_h = physical_h, physical_w  # 現在の表示座標系に合わせる
    scale_x = physical_w / unity_screen[0]
    scale_y = physical_h / unity_screen[1]
    android_x = int(unity_x * scale_x)
    android_y = int(physical_h - unity_y * scale_y)  # Y軸反転
    _run("shell", "input", "tap", str(android_x), str(android_y))

