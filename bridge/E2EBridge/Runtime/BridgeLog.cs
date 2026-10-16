using System;
using System.Text;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace E2EBridge
{
    /// <summary>
    /// アプリのログ（<see cref="Application.logMessageReceivedThreaded"/>）をリングバッファに溜め、
    /// `logs` コマンドで読み出させる（issue #85）。
    ///
    /// <para>iOS では Unity の <c>Debug.Log</c> が OS のログ（統合ログ・実機の syslog）に出ず、標準出力にしか出ない。
    /// 標準出力をつかむ方式はバッファ・デバッガ・起動し直しで取りこぼすので、**アプリの中で溜める**。
    /// シミュレータ・実機・エディタで同じ経路になり、ログの種類（<see cref="LogType"/>）が直接分かる。</para>
    ///
    /// <para>**スレッドの約束**: ハンドラはどのスレッドからも並行して呼ばれる。ロックの中で <c>Debug.*</c> を呼ばない・
    /// 読むときはロックの中で写しを取ってから整形する・ハンドラの中でログを出さない（再帰になる。C# の lock は
    /// 同じスレッドから入り直せるので、列挙中のバッファを書き換えうる）。</para>
    ///
    /// <para>ネイティブのクラッシュはプロセスごと消えるので取れない。</para>
    /// </summary>
    public static class BridgeLog
    {
        public const int Capacity = 2000;
        public const int MaxTextLength = 4000;
        public const int DefaultMax = 500;
        /// <summary>1 回の応答の文字数の目安（行単位のプロトコルで、メインスレッドで JSON を組み立てるため）。</summary>
        public const int MaxResponseChars = 256 * 1024;

        private struct Entry
        {
            public long Seq;
            public LogType Type;
            public string Message;
            public string Stack;
        }

        private static readonly object Gate = new object();
        private static readonly Entry[] Ring = new Entry[Capacity];
        private static long _next;
        private static long _dropped;
        private static string _session = NewSession();

        private static string NewSession() => Guid.NewGuid().ToString("N");

        /// <summary>
        /// **できるだけ早く**登録する（ブリッジが立つ AfterSceneLoad より前のログも溜めるため）。
        /// 登録の前に必ず外す ― エディタでドメインのリロードを切っていると、Play のたびに登録が重なり同じログが二重に入る。
        /// </summary>
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        private static void Register()
        {
            ResetBuffer();
            Application.logMessageReceivedThreaded -= Append;
            Application.logMessageReceivedThreaded += Append;
            Application.quitting -= Unregister;
            Application.quitting += Unregister;   // エディタでは Play を抜けるときにも呼ばれる
        }

        private static void Unregister()
        {
            Application.logMessageReceivedThreaded -= Append;
            Application.quitting -= Unregister;
        }

        /// <summary>バッファを空にし、新しいセッションにする（起動ごと・テスト用）。</summary>
        public static void ResetBuffer()
        {
            lock (Gate)
            {
                Array.Clear(Ring, 0, Ring.Length);
                _next = 0;
                _dropped = 0;
                _session = NewSession();
            }
        }

        /// <summary>ログを 1 件積む（ハンドラ。**ここで Debug.* を呼ばない**）。</summary>
        public static void Append(string message, string stackTrace, LogType type)
        {
            var entry = new Entry { Type = type, Message = Truncate(message), Stack = Truncate(stackTrace) };
            lock (Gate)
            {
                entry.Seq = _next;
                if (_next >= Capacity) _dropped++;
                Ring[_next % Capacity] = entry;
                _next++;
            }
        }

        private static string Truncate(string text)
        {
            if (string.IsNullOrEmpty(text)) return text ?? "";
            return text.Length <= MaxTextLength ? text : text.Substring(0, MaxTextLength) + "…(truncated)";
        }

        /// <summary>
        /// `logs` コマンド。引数 `since`（含む。省くとバッファの先頭）・`max`（既定 500・上限 2000）。
        /// 応答の大きさは約 <see cref="MaxResponseChars"/> 文字で切る（最低 1 件は返す）。続きは呼び手が `since` を進めて読む。
        /// </summary>
        public static JObject Read(JObject args)
        {
            long since = ReadNonNegative(args, "since", -1);
            int max = (int)Math.Min(Capacity, ReadNonNegative(args, "max", DefaultMax));
            if (max == 0) max = DefaultMax;

            // **ロックの中では写しを取るだけ**（整形・Debug.* はロックの外）
            Entry[] copy;
            long first, next, dropped;
            string session;
            lock (Gate)
            {
                next = _next;
                first = Math.Max(0, next - Capacity);
                dropped = _dropped;
                session = _session;
                long start = since < 0 ? first : Math.Max(since, first);
                long end = Math.Min(next, start + max);
                int count = (int)Math.Max(0, end - start);
                copy = new Entry[count];
                for (int i = 0; i < count; i++) copy[i] = Ring[(start + i) % Capacity];
            }

            var entries = new JArray();
            long chars = 0;
            foreach (var e in copy)
            {
                long size = (e.Message?.Length ?? 0) + (e.Stack?.Length ?? 0) + 64;
                if (entries.Count > 0 && chars + size > MaxResponseChars) break;
                chars += size;
                entries.Add(new JObject
                {
                    ["seq"] = e.Seq,
                    ["type"] = e.Type.ToString(),
                    ["message"] = e.Message,
                    ["stack"] = e.Stack,
                });
            }

            var logger = Debug.unityLogger;
            return new JObject
            {
                ["session"] = session,
                ["first"] = first,
                ["next"] = next,
                ["dropped"] = dropped,
                // アプリがロガーを止めていると Debug.* がイベントまで届かず、例外が無いように見える（呼び手が判定する）
                ["logEnabled"] = logger.logEnabled,
                ["filterLogType"] = logger.filterLogType.ToString(),
                ["entries"] = entries,
            };
        }

        private static long ReadNonNegative(JObject args, string key, long fallback)
        {
            var token = args[key];
            if (token == null || token.Type == JTokenType.Null) return fallback;
            if (token.Type != JTokenType.Integer)
                throw new BridgeException(ErrorCodes.BadRequest, $"'{key}' must be a non-negative integer");
            long value = token.Value<long>();
            if (value < 0) throw new BridgeException(ErrorCodes.BadRequest, $"'{key}' must be a non-negative integer");
            return value;
        }
    }
}
