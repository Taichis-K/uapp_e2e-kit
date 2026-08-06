"""iOS 実機の画面を OS 層で撮る（libimobiledevice の idevicescreenshot 経由）。

**ブリッジ（Unity）側のキャプチャと違い、画面の合成結果をそのまま撮る**ので、
WebView・ネイティブダイアログ・ソフトキーボード・広告 SDK のビューも写る。
Unity の `ScreenCapture` は Unity の描画パイプラインの結果しか撮れず、それらが欠ける。

**使える条件**: iOS 16 以前（iPhone 8 等）。iOS 17 以降は Apple が開発者サービスを
lockdownd から RemoteXPC へ移したため、この経路は `Invalid service` で失敗する
（代替は root 権限のトンネル（pymobiledevice3）か iPhone ミラーリング窓のキャプチャで、
いずれも別途セットアップが要る）。**失敗は静かに False**にして、呼び出し側が
次の手段へ落ちられるようにする（撮影は記録の付加価値であって、テストの成否ではない）。

必要な情報は `run-ios-e2e.ps1` が環境変数で渡す:

- `UAPP_E2E_IOS_DEVICE_UDID` … 対象実機の UDID。**未設定なら撮らない**
  （複数台つながっている環境で別の端末を撮って「撮れた」と扱わないため）
- `UAPP_E2E_IOS_DEVICE_MAJOR` … 実機の iOS メジャー版。**17 以降なら試行そのものをしない**
  （失敗すると分かっている経路を撮影のたびに叩くと、USB やサービスの応答が悪いときに
  タイムアウトまで止まる。未設定なら「不明」として試行はする）
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

TIMEOUT_SEC = 60

_PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _tool() -> str | None:
    return shutil.which("idevicescreenshot")


def available() -> bool:
    """iOS 実機モードで、idevicescreenshot が使え、**宛先 UDID が分かっている**こと。"""
    if os.environ.get("UAPP_E2E_IOS") != "1":
        return False
    if not os.environ.get("UAPP_E2E_IOS_DEVICE_UDID"):
        return False
    major = os.environ.get("UAPP_E2E_IOS_DEVICE_MAJOR")
    if major and major.isdigit() and int(major) >= 17:
        return False   # iOS 17 以降はこの経路が存在しない（試すだけ無駄に待つ）
    return _tool() is not None


def capture(local_path: str | Path) -> bool:
    """スクリーンショットを PNG で保存する。失敗は False（例外にしない）。

    **端末は TIFF を返すことがある**ので、拡張子を信じず先頭バイトで判定し、
    PNG でなければ macOS 標準の `sips` で変換する（PNG のつもりで TIFF を保存すると、
    レポートで開けない画像になる）。
    """
    tool = _tool()
    udid = os.environ.get("UAPP_E2E_IOS_DEVICE_UDID")
    if not tool or not udid:
        return False
    target = Path(local_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    # 前回の画像を先に消す（撮れていないのに古い画像で成功と誤判定しないため）
    try:
        target.unlink(missing_ok=True)
    except OSError:
        return False

    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "shot"
        try:
            result = subprocess.run([tool, "-u", udid, str(raw)],
                                    capture_output=True, timeout=TIMEOUT_SEC)
        except (OSError, subprocess.TimeoutExpired):
            return False
        if result.returncode != 0:
            return False
        # idevicescreenshot は拡張子が無いと自分で付ける（.png / .tiff）
        candidates = [raw, *sorted(Path(tmp).glob("shot*"))]
        source = next((p for p in candidates if p.is_file() and p.stat().st_size > 0), None)
        if source is None:
            return False
        head = source.read_bytes()[:8]
        if head == _PNG_MAGIC:
            shutil.copyfile(source, target)
        else:
            sips = shutil.which("sips")
            if not sips:
                return False
            try:
                converted = subprocess.run(
                    [sips, "-s", "format", "png", str(source), "--out", str(target)],
                    capture_output=True, timeout=TIMEOUT_SEC)
            except (OSError, subprocess.TimeoutExpired):
                return False
            if converted.returncode != 0:
                return False
    return target.exists() and target.stat().st_size > 0
