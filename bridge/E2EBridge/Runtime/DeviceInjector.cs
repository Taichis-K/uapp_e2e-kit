using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;

namespace E2EBridge
{
    /// <summary>
    /// キーボード / マウス / ゲームパッドへ合成入力を注入する（UI を経由しない入力の検証用）。
    ///
    /// <para>タッチ（<see cref="TouchInjector"/>）と同じく Input System の低レベル API に流すので、
    /// アプリ側が InputAction で読んでいても、デバイスを直読みしていても同じ経路で届く。
    /// **uGUI の hittable 判定は関係しない**（そもそも UI を経由しない入力のための道）。</para>
    ///
    /// <para>押しっぱなしの状態は自前で保持する。Input System の状態イベントは「そのフレームの
    /// デバイス全体の状態」を送る形なので、押している集合を持っていないと、
    /// 2 つ目のキーを押した瞬間に 1 つ目が離れたことになる。</para>
    ///
    /// <para>**レガシー入力バックエンド（Input Manager のみ）では届かない**。
    /// その構成では明示的に失敗させる（黙って何も起きないと、AI はアプリのバグを疑って延々と調べる）。</para>
    /// </summary>
    public static class DeviceInjector
    {
        private static readonly HashSet<Key> _keys = new HashSet<Key>();
        private static readonly HashSet<string> _mouseButtons = new HashSet<string>();
        private static readonly HashSet<GamepadButton> _padButtons = new HashSet<GamepadButton>();
        private static Vector2 _mousePos;
        private static Vector2 _leftStick;
        private static Vector2 _rightStick;

        private static Keyboard _keyboard;
        private static Mouse _mouse;
        private static Gamepad _gamepad;

        private static void RequireNewInputBackend()
        {
#if !ENABLE_INPUT_SYSTEM
            throw new BridgeException(ErrorCodes.InputBackendLegacy,
                "この構成では Input System への注入が届きません（Player Settings の Active Input Handling が " +
                "'Input Manager (Old)' のみ）。'Input System Package' か 'Both' に変更してください。" +
                "変更できない場合、キー/マウス/パッドの入力は E2E からは操作できません（内側ループで検証してください）");
#endif
        }

        // **常に専用の仮想デバイスへ注入する**（実デバイスは掴まない）。
        // エディタ実行の PC には本物のキーボード・マウス・ゲームパッドが刺さっている。
        // 実デバイスに state イベントを流すと、そのデバイス自身の報告（スティックのドリフト、
        // 人が触った操作、ドライバの定期送信）に上書きされ、テストが不安定に見える。
        // 仮想デバイスなら、注入した状態がそのまま保たれる。
        // アプリ側が読む `Gamepad.current` は「最後に入力のあったデバイス」なので、
        // 注入した時点で仮想デバイスが current になる（実デバイスを触ると奪われる＝
        // それを検知できるように input_devices で一覧を出す）。
        public const string VirtualKeyboardName = "E2EVirtualKeyboard";
        public const string VirtualMouseName = "E2EVirtualMouse";
        public const string VirtualGamepadName = "E2EVirtualGamepad";

        private static Keyboard KeyboardDevice
        {
            get
            {
                if (_keyboard == null || !_keyboard.added)
                    _keyboard = InputSystem.AddDevice<Keyboard>(VirtualKeyboardName);
                return _keyboard;
            }
        }

        private static Mouse MouseDevice
        {
            get
            {
                if (_mouse == null || !_mouse.added)
                    _mouse = InputSystem.AddDevice<Mouse>(VirtualMouseName);
                return _mouse;
            }
        }

        private static Gamepad GamepadDevice
        {
            get
            {
                if (_gamepad == null || !_gamepad.added)
                    _gamepad = InputSystem.AddDevice<Gamepad>(VirtualGamepadName);
                return _gamepad;
            }
        }

        /// <summary>
        /// 接続中の入力デバイス一覧。**実機が刺さっているかを見えるようにする**ための情報。
        ///
        /// エディタ実行では PC のゲームパッドやキーボードが同時に存在する。人がうっかり触ると
        /// テストが揺れるし、`Gamepad.current` も奪われる。原因不明の不安定さとして扱わず、
        /// 「今どのデバイスが居て、どれが仮想か」を最初から見せる。
        /// </summary>
        public static JToken Devices()
        {
            var list = new JArray();
            foreach (var device in InputSystem.devices)
            {
                var isVirtual = device.name == VirtualKeyboardName || device.name == VirtualMouseName
                                || device.name == VirtualGamepadName
                                || device.name == "E2EVirtualTouchscreen";
                list.Add(new JObject
                {
                    ["name"] = device.name,
                    ["layout"] = device.layout,
                    ["displayName"] = device.displayName,
                    ["virtual"] = isVirtual,
                    ["enabled"] = device.enabled,
                    ["current"] = IsCurrent(device)
                });
            }
            return new JObject
            {
                ["devices"] = list,
                // **仮想デバイスは種別ごとに「初回注入時」に生成される**（遅延生成）。
                // 注入前に一覧を取ると仮想デバイスが 1 つも出ないため、
                // 「実機のデバイスに注入しているのでは」と誤読される（導入先で実際に誤読され、
                // テストが KeyError: 'E2EVirtualMouse' で落ちた）。未生成の種別も created:false で並べる
                ["virtualDevices"] = new JArray
                {
                    VirtualDeviceEntry("keyboard", VirtualKeyboardName),
                    VirtualDeviceEntry("mouse", VirtualMouseName),
                    VirtualDeviceEntry("gamepad", VirtualGamepadName)
                },
                // 実機の入力機器が同時に居るか（居ても動くが、人が触れば当然干渉する）
                ["realGamepads"] = CountReal<Gamepad>(VirtualGamepadName),
                ["realKeyboards"] = CountReal<Keyboard>(VirtualKeyboardName),
                ["realMice"] = CountReal<Mouse>(VirtualMouseName)
            };
        }

        // 未生成でも「その種別は存在しうる」ことを見せる（created:false）。
        // 注入すればこの名前で生成される、という対応を一覧の中で読み取れるようにする
        private static JObject VirtualDeviceEntry(string kind, string name)
        {
            var created = false;
            foreach (var device in InputSystem.devices)
            {
                if (device.name == name) { created = true; break; }
            }
            return new JObject { ["kind"] = kind, ["name"] = name, ["created"] = created };
        }

        private static bool IsCurrent(InputDevice device)
        {
            return ReferenceEquals(device, Keyboard.current) || ReferenceEquals(device, Mouse.current)
                || ReferenceEquals(device, Gamepad.current) || ReferenceEquals(device, Touchscreen.current);
        }

        private static int CountReal<T>(string virtualName) where T : InputDevice
        {
            var count = 0;
            foreach (var device in InputSystem.devices)
                if (device is T && device.name != virtualName) count++;
            return count;
        }

        // ------------------------------------------------------------- keyboard

        public static JToken KeyDown(JObject args)
        {
            RequireNewInputBackend();
            var key = RequireKey(args);
            _keys.Add(key);
            FlushKeyboard();
            return KeyAck(key, true);
        }

        public static JToken KeyUp(JObject args)
        {
            RequireNewInputBackend();
            var key = RequireKey(args);
            if (!_keys.Remove(key))
                throw new BridgeException(ErrorCodes.NotPressed, $"key '{key}' is not down");
            FlushKeyboard();
            return KeyAck(key, false);
        }

        private static void FlushKeyboard()
        {
            // 押している集合をまとめて 1 つの状態として送る（差分ではなく状態を送る API のため）
            var state = new KeyboardState();
            foreach (var key in _keys) state.Set(key, true);
            InputSystem.QueueStateEvent(KeyboardDevice, state);
        }

        // ---------------------------------------------------------------- mouse

        public static JToken MouseMove(JObject args)
        {
            RequireNewInputBackend();
            _mousePos = RequirePos(args);
            FlushMouse(Vector2.zero);
            return MouseAck();
        }

        public static JToken MouseDown(JObject args)
        {
            RequireNewInputBackend();
            var button = RequireButton(args);
            if (args["x"] != null && args["y"] != null) _mousePos = RequirePos(args);
            if (!_mouseButtons.Add(button))
                throw new BridgeException(ErrorCodes.AlreadyPressed, $"mouse button '{button}' is already down");
            FlushMouse(Vector2.zero);
            return MouseAck();
        }

        public static JToken MouseUp(JObject args)
        {
            RequireNewInputBackend();
            var button = RequireButton(args);
            if (!_mouseButtons.Remove(button))
                throw new BridgeException(ErrorCodes.NotPressed, $"mouse button '{button}' is not down");
            FlushMouse(Vector2.zero);
            return MouseAck();
        }

        public static JToken MouseScroll(JObject args)
        {
            RequireNewInputBackend();
            var dx = args["dx"] != null ? (float)args["dx"] : 0f;
            var dy = args["dy"] != null ? (float)args["dy"] : 0f;
            FlushMouse(new Vector2(dx, dy));
            return MouseAck();
        }

        private static void FlushMouse(Vector2 scroll)
        {
            var state = new MouseState { position = _mousePos, scroll = scroll };
            if (_mouseButtons.Contains("left")) state.WithButton(MouseButton.Left);
            if (_mouseButtons.Contains("right")) state.WithButton(MouseButton.Right);
            if (_mouseButtons.Contains("middle")) state.WithButton(MouseButton.Middle);
            InputSystem.QueueStateEvent(MouseDevice, state);
        }

        // -------------------------------------------------------------- gamepad

        public static JToken PadButtonDown(JObject args)
        {
            RequireNewInputBackend();
            var button = RequirePadButton(args);
            _padButtons.Add(button);
            FlushGamepad();
            return PadAck();
        }

        public static JToken PadButtonUp(JObject args)
        {
            RequireNewInputBackend();
            var button = RequirePadButton(args);
            if (!_padButtons.Remove(button))
                throw new BridgeException(ErrorCodes.NotPressed, $"gamepad button '{button}' is not down");
            FlushGamepad();
            return PadAck();
        }

        public static JToken PadStick(JObject args)
        {
            RequireNewInputBackend();
            var stick = ((string)args["stick"] ?? "left").ToLowerInvariant();
            var value = new Vector2(
                args["x"] != null ? (float)args["x"] : 0f,
                args["y"] != null ? (float)args["y"] : 0f);
            // 実機のスティックは正規化された範囲しか出さない。範囲外を送ると
            // アプリ側の「入力は -1〜1」という前提を壊すのでここで丸める
            value = Vector2.ClampMagnitude(value, 1f);
            if (stick == "left") _leftStick = value;
            else if (stick == "right") _rightStick = value;
            else throw new BridgeException(ErrorCodes.BadRequest, "'stick' は left / right");
            FlushGamepad();
            return PadAck();
        }

        private static void FlushGamepad()
        {
            var state = new GamepadState { leftStick = _leftStick, rightStick = _rightStick };
            foreach (var button in _padButtons) state.WithButton(button);
            InputSystem.QueueStateEvent(GamepadDevice, state);
        }

        // ---------------------------------------------------------------- reset

        /// <summary>押しっぱなしを全部離す。テスト間で状態を持ち越さないための後始末。</summary>
        public static JToken Reset()
        {
            var released = _keys.Count + _mouseButtons.Count + _padButtons.Count;
            _keys.Clear();
            _mouseButtons.Clear();
            _padButtons.Clear();
            _leftStick = Vector2.zero;
            _rightStick = Vector2.zero;
#if ENABLE_INPUT_SYSTEM
            FlushKeyboard();
            FlushMouse(Vector2.zero);
            FlushGamepad();
#endif
            return new JObject { ["released"] = released };
        }

        // --------------------------------------------------------------- helper

        private static Key RequireKey(JObject args)
        {
            var name = (string)args["key"];
            if (string.IsNullOrEmpty(name))
                throw new BridgeException(ErrorCodes.BadRequest, "'key' is required（例: space / w / escape / f1）");
            if (Enum.TryParse<Key>(name, true, out var key) && key != Key.None) return key;
            throw new BridgeException(ErrorCodes.BadRequest,
                $"unknown key '{name}'. available: {string.Join(", ", SampleKeyNames())}…（Input System の Key 列挙名）");
        }

        private static IEnumerable<string> SampleKeyNames()
        {
            // 全部出すと数百件になるので、迷いやすいものだけ挙げる
            yield return "space";
            yield return "enter";
            yield return "escape";
            yield return "leftShift";
            yield return "w / a / s / d";
            yield return "upArrow / downArrow";
            yield return "digit1";
            yield return "f1";
        }

        private static string RequireButton(JObject args)
        {
            var name = ((string)args["button"] ?? "left").ToLowerInvariant();
            if (name != "left" && name != "right" && name != "middle")
                throw new BridgeException(ErrorCodes.BadRequest, "'button' は left / right / middle");
            return name;
        }

        private static GamepadButton RequirePadButton(JObject args)
        {
            var name = (string)args["button"];
            if (string.IsNullOrEmpty(name))
                throw new BridgeException(ErrorCodes.BadRequest,
                    "'button' is required（例: buttonSouth / buttonEast / dpadUp / leftShoulder / start）");
            // Input System の**コントロール名**（buttonSouth 等）と GamepadButton 列挙名（South 等）は
            // 綴りが違う。バインディングやドキュメントで目にするのは前者なので、両方受け取る
            var normalized = name.Trim();
            if (normalized.StartsWith("button", StringComparison.OrdinalIgnoreCase) && normalized.Length > 6)
                normalized = normalized.Substring(6);
            if (Enum.TryParse<GamepadButton>(normalized, true, out var button)) return button;
            throw new BridgeException(ErrorCodes.BadRequest,
                $"unknown gamepad button '{name}'. available: {string.Join(", ", Enum.GetNames(typeof(GamepadButton)))}");
        }

        private static Vector2 RequirePos(JObject args)
        {
            var x = args["x"];
            var y = args["y"];
            if (x == null || y == null)
                throw new BridgeException(ErrorCodes.BadRequest, "'x' and 'y' are required");
            return new Vector2((float)x, (float)y);
        }

        private static JToken KeyAck(Key key, bool down)
        {
            return new JObject
            {
                ["key"] = key.ToString(),
                ["down"] = down,
                ["keysDown"] = _keys.Count
            };
        }

        private static JToken MouseAck()
        {
            return new JObject
            {
                ["x"] = _mousePos.x,
                ["y"] = _mousePos.y,
                ["buttonsDown"] = new JArray(_mouseButtons)
            };
        }

        private static JToken PadAck()
        {
            return new JObject
            {
                ["buttonsDown"] = new JArray(System.Linq.Enumerable.Select(_padButtons, b => b.ToString())),
                ["leftStick"] = new JObject { ["x"] = _leftStick.x, ["y"] = _leftStick.y },
                ["rightStick"] = new JObject { ["x"] = _rightStick.x, ["y"] = _rightStick.y }
            };
        }
    }
}
