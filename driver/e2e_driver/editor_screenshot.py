"""エディタ直結モードで画面を PNG として撮る（Unity CLI 経由）。

デバイス実行では `adb screencap` を使うが、エディタ直結では adb を使わない（使うと
実機を検証してしまう）。代わりに Unity CLI から Play 中のエディタへコードを送り、
`ScreenCapture.CaptureScreenshot` で**実際のフレーム**を書き出させる。

**`screenshot` コマンド（pipeline 同梱）は使わない**: あれはカメラの描画だけを撮るため、
Screen Space - Overlay の uGUI が 1 つも写らない（実測。空の背景だけの PNG になる）。
UI の E2E で画像を残す意味が無くなるので、フレームごと撮る方を採る。

**使えない環境では静かに諦める**（撮影は記録の付加価値であって、テストの成否ではない）。
必要な情報は `run-e2e.ps1 -Editor` が環境変数で渡す:

- `UAPP_E2E_UNITY_CLI`    … unity 実行ファイルのパス
- `UAPP_E2E_PROJECT_PATH` … 対象 Unity プロジェクトのパス（複数エディタ起動時の宛先指定）
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

TIMEOUT_SEC = 60
# CaptureScreenshot はフレーム終端で非同期に書き出す。書き出し完了までポーリングする
WAIT_SEC = 8.0
POLL_SEC = 0.25


def _cli() -> str | None:
    explicit = os.environ.get("UAPP_E2E_UNITY_CLI")
    if explicit and Path(explicit).exists():
        return explicit
    return shutil.which("unity")


def available() -> bool:
    """エディタ直結モードで、Unity CLI が使え、**宛先プロジェクトが分かっている**こと。

    プロジェクトを指定せずに撃つと Unity CLI の既定の接続先へ行く。エディタを複数
    起動している環境（並行開発では普通）では**別プロジェクトの画面を撮って
    「撮れた」と扱う**ことになるので、指定が無い場合は使わない。
    """
    return (os.environ.get("UAPP_E2E_EDITOR") == "1"
            and _cli() is not None
            and bool(os.environ.get("UAPP_E2E_PROJECT_PATH")))


def _cli_global_args() -> list[str]:
    """Unity CLI へ毎回渡すグローバル引数（サブコマンドより前に置く）。

    PowerShell 側の `Get-UappUnityCliGlobalArgs` と対になる。**片方だけに付けると
    「Play 制御は通るのにスクリーンショットだけ落ちる」**という切り分けにくい欠け方をする。
    """
    if os.environ.get("UAPP_E2E_UNITY_CLI_PROXY_DISABLE") == "1":
        return ["--proxy-disable"]
    return []


def _run(argv: list[str]) -> dict | None:
    try:
        result = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8",
                                errors="replace", timeout=TIMEOUT_SEC)
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        return json.loads(result.stdout or "{}")
    except ValueError:
        return None


def capture(out_path: Path) -> bool:
    """Play 中のフレームを `out_path` へ保存する。撮れたら True。"""
    cli = _cli()
    if cli is None:
        return False
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()          # 前回の画像を「今回撮れた」と誤認しない

    project = os.environ.get("UAPP_E2E_PROJECT_PATH")
    if not project:
        return False               # 宛先不明のまま撮ると別プロジェクトの画面を掴みうる
    # **PowerShell 側と同じグローバル引数を付ける**。プロキシ配下では Unity CLI が
    # localhost 宛ての Pipeline 通信までプロキシへ流して 503 になるため、
    # `--proxy-disable` が無いと**ジャーニー画像と失敗時画像だけが静かに欠落**する
    # （Play 制御と pytest は PowerShell 側で通っているので気づきにくい）。
    # 有効化は run-e2e.ps1 の -UnityCliProxyDisable / 環境変数（どちらでも同じ）
    argv = [cli, *_cli_global_args(), "cmd", "--project-path", project]
    # C# の逐語的文字列に埋めるので " だけ二重化する（Windows のパス区切りはそのまま渡せる）
    literal = str(out_path.resolve()).replace('"', '""')
    argv += ["eval", "--code",
             f'UnityEngine.ScreenCapture.CaptureScreenshot(@"{literal}"); return "queued";',
             "--format", "json", "--no-banner"]
    response = _run(argv)
    if not response or not response.get("success"):
        return False

    deadline = time.monotonic() + WAIT_SEC
    last_size = -1
    while time.monotonic() < deadline:
        time.sleep(POLL_SEC)
        if not out_path.exists():
            continue
        size = out_path.stat().st_size
        if size > 0 and size == last_size:
            return True            # 2 回続けて同じサイズ＝書き出し完了
        last_size = size
    return out_path.exists() and out_path.stat().st_size > 0
