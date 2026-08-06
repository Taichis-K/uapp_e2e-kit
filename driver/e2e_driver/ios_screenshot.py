"""iOS シミュレータモードで画面を PNG として撮る（simctl 経由）。

デバイス実行では `adb screencap`、エディタ直結では Unity CLI を使うが、
iOS シミュレータでは `xcrun simctl io <UDID> screenshot` で実際の画面を撮れる。
editor_screenshot と同じ約束: **使えない環境では静かに諦める**
（撮影は記録の付加価値であって、テストの成否ではない）。

必要な情報は `run-ios-e2e.ps1` が環境変数で渡す:

- `UAPP_E2E_IOS_UDID` … 対象シミュレータの UDID。**未設定なら撮らない** —
  `booted` へのフォールバックはしない（複数シミュレータ起動時に**別の個体の画面を撮って
  「撮れた」と扱う**ことになる。接続先を UDID で固定する run スクリプトの設計と揃える）
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

TIMEOUT_SEC = 30


def _xcrun() -> str | None:
    return shutil.which("xcrun")


def available() -> bool:
    """iOS シミュレータモードで、xcrun が使え、**宛先 UDID が分かっている**こと。"""
    return (os.environ.get("UAPP_E2E_IOS") == "1"
            and _xcrun() is not None
            and bool(os.environ.get("UAPP_E2E_IOS_UDID")))


def capture(local_path: str | Path) -> bool:
    """スクリーンショットを保存する。失敗は False（例外にしない。付加価値であって成否ではない）。"""
    xcrun = _xcrun()
    udid = os.environ.get("UAPP_E2E_IOS_UDID")
    if not xcrun or not udid:
        return False
    local = Path(local_path)
    local.parent.mkdir(parents=True, exist_ok=True)
    # **前回の画像を先に消す**。残したまま撮ると「exit 0 なのに何も書かれなかった」場合に
    # 古い画像を見て成功と誤判定する（ジャーニーは同じ screen_id を毎回上書きするため、
    # 再実行では既存ファイルがあるのが普通）
    try:
        local.unlink(missing_ok=True)
    except OSError:
        return False
    try:
        result = subprocess.run(
            [xcrun, "simctl", "io", udid, "screenshot", str(local)],
            capture_output=True, timeout=TIMEOUT_SEC,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    # **終了コードだけで成功と断定しない**。0 でもファイルが出来ていない・空という
    # 壊れ方を「撮れた」と記録すると、レポートが壊れた画像リンクだらけになる
    return result.returncode == 0 and local.exists() and local.stat().st_size > 0
