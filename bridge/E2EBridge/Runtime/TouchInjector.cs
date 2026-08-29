using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;
using TouchPhase = UnityEngine.InputSystem.TouchPhase;

namespace E2EBridge
{
    /// <summary>
    /// New Input System の Touchscreen へ合成タッチを注入する。
    /// pointerId ごとに down/move/up を管理し、任意本数のマルチタッチを表現できる。
    /// 注入イベントは実タッチと同じ入力パイプライン（EnhancedTouch / InputSystemUIInputModule）を通る。
    /// 座標系は Unity スクリーン座標（左下原点・ピクセル）。
    /// </summary>
    public static class TouchInjector
    {
        private class PointerState
        {
            public int TouchId;
            public Vector2 Position;
        }

        private static Touchscreen _device;
        private static int _nextTouchId = 1;
        private static readonly Dictionary<int, PointerState> _pointers = new Dictionary<int, PointerState>();

        public static int ActiveCount => _pointers.Count;

        private static Touchscreen Device
        {
            get
            {
                if (_device == null || !_device.added)
                    _device = Touchscreen.current
                              ?? InputSystem.AddDevice<Touchscreen>(DeviceInjector.VirtualTouchscreenName);
                return _device;
            }
        }

        /// <summary>
        /// **今まさに注入先にしているデバイス**（まだ 1 度も注入していなければ null）。
        ///
        /// 復旧処理（<see cref="DeviceInjector.RepairDisabledDevices"/>）が
        /// 「E2E が実際に使っているデバイスだけ」を再有効化するために使う。
        /// `Touchscreen.current` で代用してはならない — ここは最初に選んだデバイスを
        /// 掴み続けるので、別のタッチデバイスが入力を出せば `current` は移り、
        /// 「注入先でないものを起こして、注入先は無効のまま」になる。
        /// </summary>
        internal static Touchscreen CurrentTarget
        {
            get { return (_device != null && _device.added) ? _device : null; }
        }

        public static JToken Down(JObject args)
        {
            var id = RequireInt(args, "pointerId");
            var pos = RequirePos(args);
            if (_pointers.ContainsKey(id))
                // **次の一手を書く**。異常終了（walker を kill する等）で押下が残ると、
                // 以後のタップが全部これで落ちる。症状は「特定のボタンが効かない」に見えるので、
                // 解放手段が書かれていないと**アプリ側の不具合を探しに行く**（導入先で実際に起きた）
                throw new BridgeException(ErrorCodes.PointerAlreadyDown,
                    $"pointerId {id} is already down"
                    + $" — 前の操作が異常終了して押下が残っている可能性がある。"
                    + $"pointer_up({id}) か input_reset() で解放できる");

            var state = new PointerState { TouchId = NextTouchId(), Position = pos };
            _pointers[id] = state;
            Queue(state.TouchId, TouchPhase.Began, pos, Vector2.zero);
            return Ack(id, pos);
        }

        public static JToken Move(JObject args)
        {
            var id = RequireInt(args, "pointerId");
            var pos = RequirePos(args);
            var state = RequirePointer(id);

            var delta = pos - state.Position;
            state.Position = pos;
            Queue(state.TouchId, TouchPhase.Moved, pos, delta);
            return Ack(id, pos);
        }

        public static JToken Up(JObject args)
        {
            var id = RequireInt(args, "pointerId");
            var state = RequirePointer(id);

            Queue(state.TouchId, TouchPhase.Ended, state.Position, Vector2.zero);
            _pointers.Remove(id);
            return Ack(id, state.Position);
        }

        /// <summary>
        /// テスト間クリーンアップ用: アクティブな全ポインタを解放する。
        ///
        /// <para>**台帳の破棄は必ず行う**（`finally`）。`Queue` が 1 つでも失敗すると
        /// `_pointers` が残り、**復旧コマンドを打ったのに `POINTER_ALREADY_DOWN` のまま**になる
        /// ― 直そうとしている状態を、復旧路の失敗が固定してしまう（codex の指摘）。
        /// Ended を送れなかったぶんはアプリ側に押下が残りうるが、
        /// **こちら側が「押している」と思い続けるよりは軽い**（次の `pointer_down` が通る）。</para>
        ///
        /// <para>1 つの失敗で残り全部を諦めないよう、**送出は 1 件ずつ切り離す**。</para>
        /// </summary>
        public static JToken Reset()
        {
            var released = _pointers.Count;
            try
            {
                foreach (var kv in _pointers)
                {
                    try { Queue(kv.Value.TouchId, TouchPhase.Ended, kv.Value.Position, Vector2.zero); }
                    catch (Exception ex) { Debug.LogException(ex); }
                }
            }
            finally { _pointers.Clear(); }
            return new JObject { ["released"] = released };
        }

        private static void Queue(int touchId, TouchPhase phase, Vector2 pos, Vector2 delta)
        {
            // エディタでは Game view のフォーカス状態に注入が左右されないようにする（初回のみ）
            EditorInputRouting.EnsureGameViewRouting();
            // **注入先を確定させてから**、無効なら起こす。順序が逆だと初回注入で漏れる:
            // EnsureGameViewRouting 内の復旧は「E2E が使っているデバイス」しか触らないが、
            // 1 度も注入していない時点では注入先がまだ決まっていない。そのまま無効な
            // Touchscreen をキャッシュすると、以後 input_reset まで一切届かない
            //（キー/マウス/パッドは注入先が固定名の仮想デバイスなのでこの穴は無い）
            var device = Device;
            DeviceInjector.EnsureEnabled(device);
            InputSystem.QueueStateEvent(device, new TouchState
            {
                touchId = touchId,
                phase = phase,
                position = pos,
                delta = delta
            });
        }

        private static int NextTouchId()
        {
            // touchId は 0 より大きい必要がある
            var id = _nextTouchId++;
            if (_nextTouchId > 1_000_000) _nextTouchId = 1;
            return id;
        }

        private static PointerState RequirePointer(int id)
        {
            if (!_pointers.TryGetValue(id, out var state))
                throw new BridgeException(ErrorCodes.PointerNotDown, $"pointerId {id} is not down");
            return state;
        }

        private static int RequireInt(JObject args, string key)
        {
            var token = args[key];
            if (token == null || token.Type != JTokenType.Integer)
                throw new BridgeException(ErrorCodes.BadRequest, $"'{key}' (int) is required");
            return (int)token;
        }

        private static Vector2 RequirePos(JObject args)
        {
            var x = args["x"];
            var y = args["y"];
            if (x == null || y == null)
                throw new BridgeException(ErrorCodes.BadRequest, "'x' and 'y' are required");
            return new Vector2((float)x, (float)y);
        }

        private static JToken Ack(int pointerId, Vector2 pos)
        {
            return new JObject
            {
                ["pointerId"] = pointerId,
                ["x"] = pos.x,
                ["y"] = pos.y,
                ["activePointers"] = _pointers.Count
            };
        }
    }
}
