using System;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace E2EBridge
{
    /// <summary>
    /// リクエスト JSON をコマンドへディスパッチする。必ずメインスレッドで呼ぶこと。
    /// リクエスト:  {"id": 1, "cmd": "dump", "args": {...}}
    /// レスポンス:  {"id": 1, "ok": true, "result": {...}}
    ///           / {"id": 1, "ok": false, "error": {"code": "...", "message": "..."}}
    /// </summary>
    public static class CommandProcessor
    {
        /// <summary>
        /// リクエストを解析してコマンド名を取り出す（**非同期コマンドの振り分け用**）。
        /// 解析できないリクエストは false を返し、通常経路（Process）でエラー応答させる。
        /// </summary>
        public static bool TryPeek(string requestJson, out JObject req, out string cmd)
        {
            req = null; cmd = null;
            try
            {
                req = JObject.Parse(requestJson);
                cmd = (string)req["cmd"];
                return cmd != null;
            }
            catch { return false; }
        }

        /// <summary>非同期コマンド（フレーム終端を待つ等）の結果を成功応答へ包む。</summary>
        public static string Success(JToken id, JToken result)
        {
            return new JObject { ["id"] = id, ["ok"] = true, ["result"] = result }.ToString(Formatting.None);
        }

        /// <summary>非同期コマンドの失敗を通常のエラー応答形式へ包む。</summary>
        public static string Failure(JToken id, string code, string message)
        {
            return new JObject
            {
                ["id"] = id, ["ok"] = false,
                ["error"] = new JObject { ["code"] = code, ["message"] = message }
            }.ToString(Formatting.None);
        }

        public static string Process(string requestJson)
        {
            JToken id = null;
            try
            {
                var req = JObject.Parse(requestJson);
                id = req["id"];
                var cmd = (string)req["cmd"] ?? throw new BridgeException(ErrorCodes.BadRequest, "'cmd' is required");
                var args = req["args"] as JObject ?? new JObject();

                JToken result;
                switch (cmd)
                {
                    case "ping":          result = Ping(); break;
                    case "dump":          result = HierarchyDumper.Dump(args); break;
                    case "resolve":       result = HierarchyDumper.Resolve(args); break;
                    case "get":           result = HierarchyDumper.GetProperty(args); break;
                    case "pointer_down":  result = TouchInjector.Down(args); break;
                    case "pointer_move":  result = TouchInjector.Move(args); break;
                    case "pointer_up":    result = TouchInjector.Up(args); break;
                    case "pointer_reset": result = TouchInjector.Reset(); break;
                // UI を経由しない入力（キー・マウス・パッド）。hittable 判定は関係しない
                case "key_down":         result = DeviceInjector.KeyDown(args); break;
                case "key_up":           result = DeviceInjector.KeyUp(args); break;
                case "mouse_move":       result = DeviceInjector.MouseMove(args); break;
                case "mouse_down":       result = DeviceInjector.MouseDown(args); break;
                case "mouse_up":         result = DeviceInjector.MouseUp(args); break;
                case "mouse_scroll":     result = DeviceInjector.MouseScroll(args); break;
                case "pad_button_down":  result = DeviceInjector.PadButtonDown(args); break;
                case "pad_button_up":    result = DeviceInjector.PadButtonUp(args); break;
                case "pad_stick":        result = DeviceInjector.PadStick(args); break;
                case "input_reset":      result = DeviceInjector.Reset(); break;
                case "input_devices":    result = DeviceInjector.Devices(); break;
                    case "ngui_event":    result = NguiAdapter.HandleEvent(args); break;
                    default:
                        throw new BridgeException(ErrorCodes.UnknownCommand, $"unknown command: {cmd}");
                }

                return new JObject { ["id"] = id, ["ok"] = true, ["result"] = result }
                    .ToString(Formatting.None);
            }
            catch (BridgeException be)
            {
                return Error(id, be.Code, be.Message);
            }
            catch (JsonException je)
            {
                return Error(id, ErrorCodes.BadRequest, $"invalid json: {je.Message}");
            }
            catch (Exception ex)
            {
                Debug.LogException(ex);
                return Error(id, ErrorCodes.Internal, ex.ToString());
            }
        }

        public static string InternalError(Exception ex) => Error(null, ErrorCodes.Internal, ex.ToString());

        private static string Error(JToken id, string code, string message)
        {
            return new JObject
            {
                ["id"] = id,
                ["ok"] = false,
                ["error"] = new JObject { ["code"] = code, ["message"] = message }
            }.ToString(Formatting.None);
        }

        private static JToken Ping()
        {
            return new JObject
            {
                ["bridge"] = "1.0",
                ["app"] = Application.identifier,
                ["appVersion"] = Application.version,
                ["unity"] = Application.unityVersion,
                ["platform"] = Application.platform.ToString(),
                // **どのプロジェクトのエディタか**を識別するために返す（issue #26）。
                // platform だけでは、同じ editorBridgePort を先に握った**別プロジェクトの
                // エディタ**を見分けられず、UI が似ていれば偽の緑になる。
                // 意味を持つのは Editor のときだけ（dataPath の親＝プロジェクトルート）なので、
                // プレイヤーでは返さない（端末上のパスを送っても照合に使えないため）
                ["project"] = Application.isEditor
                    ? System.IO.Path.GetDirectoryName(Application.dataPath)
                    : null,
                // シーン名は「遷移を待つ」ポーリングの定番情報。dump の全ツリーを取らずに済むよう
                // ping に含める（取得コストはほぼゼロ。導入先要望: ping().get("scene") が None で
                // リセット待ちループが空回りした）
                ["scene"] = UnityEngine.SceneManagement.SceneManager.GetActiveScene().name,
                ["screen"] = new JObject { ["w"] = Screen.width, ["h"] = Screen.height },
                ["activePointers"] = TouchInjector.ActiveCount,
                ["ngui"] = NguiAdapter.Available
            };
        }
    }
}
