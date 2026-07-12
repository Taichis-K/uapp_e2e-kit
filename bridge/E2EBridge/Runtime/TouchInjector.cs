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
                    _device = Touchscreen.current ?? InputSystem.AddDevice<Touchscreen>("E2EVirtualTouchscreen");
                return _device;
            }
        }

        public static JToken Down(JObject args)
        {
            var id = RequireInt(args, "pointerId");
            var pos = RequirePos(args);
            if (_pointers.ContainsKey(id))
                throw new BridgeException(ErrorCodes.PointerAlreadyDown, $"pointerId {id} is already down");

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

        /// <summary>テスト間クリーンアップ用: アクティブな全ポインタを解放する。</summary>
        public static JToken Reset()
        {
            foreach (var kv in _pointers)
                Queue(kv.Value.TouchId, TouchPhase.Ended, kv.Value.Position, Vector2.zero);
            var released = _pointers.Count;
            _pointers.Clear();
            return new JObject { ["released"] = released };
        }

        private static void Queue(int touchId, TouchPhase phase, Vector2 pos, Vector2 delta)
        {
            InputSystem.QueueStateEvent(Device, new TouchState
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
