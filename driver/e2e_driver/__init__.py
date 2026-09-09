from .client import (BridgeClient, BridgeError, BlockedError, WrongBridgeTargetError,
                     wait_for_bridge)
from .devices import Gamepad, Keyboard, Mouse
from .gestures import Gestures
# **アプリの外を触る口も入口に出す**（issue #66）。計装はアプリの中にいるので、
# 外部ブラウザ・システムダイアログ・キーボード・他アプリは dump にも tap にも出てこない。
# そこを埋めるのが Android=adb（uiautomator）/ iOS=os_agent（XCUITest）で、
# **adb だけを公開していたので iOS 側は存在に気づかれなかった**
from . import adb, os_agent

__all__ = ["BridgeClient", "BridgeError", "BlockedError", "WrongBridgeTargetError", "Gestures",
           "wait_for_bridge",
           "Keyboard", "Mouse", "Gamepad", "adb", "os_agent"]
