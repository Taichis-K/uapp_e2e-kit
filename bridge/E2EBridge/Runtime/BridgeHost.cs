using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using UnityEngine;

namespace E2EBridge
{
    /// <summary>
    /// TCP サーバー本体。行区切り JSON（1リクエスト=1行、1レスポンス=1行）。
    /// ソケット I/O はバックグラウンドスレッド、コマンド実行は Update() でメインスレッド。
    /// 接続は adb forward 経由の localhost のみ受け付ける。
    /// </summary>
    public class BridgeHost : MonoBehaviour
    {
        public const int DefaultPort = 13333;
        private const int ResponseTimeoutMs = 30000;
        // 別の計装アプリ等が同一ポートを握っている場合の自己回復（プロセス回収待ち）
        private const float BindRetryIntervalSec = 2f;
        private const int BindRetryMaxAttempts = 30;

        private TcpListener _listener;
        private Thread _acceptThread;
        private volatile bool _running;
        private int _port;

        private class Pending
        {
            public string RequestJson;
            public readonly TaskCompletionSource<string> Response =
                new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        private readonly ConcurrentQueue<Pending> _queue = new ConcurrentQueue<Pending>();

        /// <summary>
        /// 待ち受けポートの解決。複数エディタ/複数計装アプリの同時運用のために外部から変更可能。
        /// 1) CLI引数 -e2eBridgePort <n>  2) 環境変数 UAPP_E2E_BRIDGE_PORT
        /// 3) Android実機/エミュレーター: 起動Intentの extra "uapp_e2e_port"
        ///    （run-e2e.ps1 が e2e-config.json の devicePort を `am start --ei uapp_e2e_port <n>` で渡す。
        ///      同一デバイスに計装アプリが複数あってもアプリごとにポートを分けられる）
        /// 4) エディタのみ: プロジェクト直下 e2e-config.json の editorBridgePort  5) 既定 13333
        /// いずれの経路も 1〜65535 のみ採用（値域外は警告して次の候補へ。
        /// Pythonドライバ側の解決（resolve_port）と挙動を一致させ、片側だけフォールバックする不整合を防ぐ）。
        /// </summary>
        private static int ResolvePort()
        {
            var args = Environment.GetCommandLineArgs();
            for (var i = 0; i < args.Length - 1; i++)
                if (args[i] == "-e2eBridgePort" && int.TryParse(args[i + 1], out var fromArg) && IsValidPort(fromArg, "-e2eBridgePort"))
                    return fromArg;

            var env = Environment.GetEnvironmentVariable("UAPP_E2E_BRIDGE_PORT");
            if (!string.IsNullOrEmpty(env) && int.TryParse(env, out var fromEnv) && IsValidPort(fromEnv, "UAPP_E2E_BRIDGE_PORT"))
                return fromEnv;

#if UNITY_ANDROID && !UNITY_EDITOR
            try
            {
                using (var player = new AndroidJavaClass("com.unity3d.player.UnityPlayer"))
                using (var activity = player.GetStatic<AndroidJavaObject>("currentActivity"))
                using (var intent = activity.Call<AndroidJavaObject>("getIntent"))
                {
                    var fromIntent = intent.Call<int>("getIntExtra", "uapp_e2e_port", 0);
                    if (fromIntent != 0 && IsValidPort(fromIntent, "uapp_e2e_port"))
                        return fromIntent;
                }
            }
            catch (Exception ex)
            {
                Debug.LogWarning($"[E2EBridge] 起動Intentのポート読み取りに失敗（既定値を使用）: {ex.Message}");
            }
#endif

#if UNITY_EDITOR
            try
            {
                // サンプル配置（プロジェクト直下）→ 導入キット配置（uapp_e2e/ 内）の順で探す
                var candidates = new[]
                {
                    Path.Combine(Application.dataPath, "..", "e2e-config.json"),
                    Path.Combine(Application.dataPath, "..", "uapp_e2e", "e2e-config.json")
                };
                foreach (var configPath in candidates)
                {
                    if (!File.Exists(configPath)) continue;
                    var config = Newtonsoft.Json.Linq.JObject.Parse(File.ReadAllText(configPath));
                    // (int?) キャストは bool/float も Convert.ToInt32 で変換してしまうため型を限定し、
                    // Python ドライバ側（_parse_port: 整数と10進数字文字列のみ受理）と判定を揃える
                    var token = config["editorBridgePort"];
                    int? fromConfig = null;
                    if (token != null)
                    {
                        if (token.Type == Newtonsoft.Json.Linq.JTokenType.Integer)
                            fromConfig = (int)token;
                        else if (token.Type == Newtonsoft.Json.Linq.JTokenType.String
                                 && int.TryParse((string)token, out var parsedConfig))
                            fromConfig = parsedConfig;
                        else
                            Debug.LogWarning($"[E2EBridge] editorBridgePort={token} は整数でないため無視します");
                    }
                    if (fromConfig.HasValue && IsValidPort(fromConfig.Value, "editorBridgePort"))
                        return fromConfig.Value;
                    break;
                }
            }
            catch (Exception ex)
            {
                Debug.LogWarning($"[E2EBridge] e2e-config.json の読み込みに失敗: {ex.Message}");
            }
#endif
            return DefaultPort;
        }

        private static bool IsValidPort(int port, string source)
        {
            if (port >= 1 && port <= 65535)
                return true;
            Debug.LogWarning($"[E2EBridge] {source} のポート {port} は値域外（1〜65535）のため無視します");
            return false;
        }

        private void Awake()
        {
            _port = ResolvePort();
            if (TryStartListener())
                return;
            // Address already in use 等で失敗しても一度で諦めず、ポート解放を待って再試行する
            //（終了直後の別計装アプリのソケットがOSに回収されるまで時間差があるため）
            StartCoroutine(RetryStartListener());
        }

        private bool TryStartListener()
        {
            try
            {
                _listener = new TcpListener(IPAddress.Loopback, _port);
                _listener.Start();
                _running = true;
                _acceptThread = new Thread(AcceptLoop) { IsBackground = true, Name = "E2EBridge.Accept" };
                _acceptThread.Start();
                Debug.Log($"[E2EBridge] listening on 127.0.0.1:{_port}");
                return true;
            }
            catch (Exception ex)
            {
                _listener = null;
                Debug.LogWarning($"[E2EBridge] bind failed (port {_port}): {ex.Message} — リトライします");
                return false;
            }
        }

        private System.Collections.IEnumerator RetryStartListener()
        {
            for (var attempt = 1; attempt <= BindRetryMaxAttempts; attempt++)
            {
                yield return new WaitForSeconds(BindRetryIntervalSec);
                if (TryStartListener())
                    yield break;
            }
            Debug.LogError($"[E2EBridge] failed to start: port {_port} が解放されない" +
                           "（別の計装アプリがこのデバイスで起動していないか確認）");
        }

        private void Update()
        {
            while (_queue.TryDequeue(out var pending))
            {
                string response;
                try
                {
                    response = CommandProcessor.Process(pending.RequestJson);
                }
                catch (Exception ex)
                {
                    // CommandProcessor 内で捕捉されるはずだが、最後の砦
                    response = CommandProcessor.InternalError(ex);
                }
                pending.Response.TrySetResult(response);
            }
        }

        private void AcceptLoop()
        {
            while (_running)
            {
                try
                {
                    var client = _listener.AcceptTcpClient();
                    // クライアントごとに独立スレッドで応対する。直列応対だと、不正終了した
                    // クライアントの残留接続（ReadLine が返らない）が新しい接続を永久に塞ぐ。
                    // コマンド実行は _queue 経由でメインスレッド直列のまま（並行接続でも安全）
                    new Thread(() => Serve(client)) { IsBackground = true, Name = "E2EBridge.Client" }.Start();
                }
                catch (SocketException)
                {
                    // listener.Stop() による中断
                }
                catch (Exception ex)
                {
                    Debug.LogWarning($"[E2EBridge] accept error: {ex.Message}");
                }
            }
        }

        private void Serve(TcpClient client)
        {
            try
            {
                ServeClient(client);
            }
            catch (Exception ex)
            {
                Debug.LogWarning($"[E2EBridge] client error: {ex.Message}");
            }
            finally
            {
                client.Close();
            }
        }

        private void ServeClient(TcpClient client)
        {
            using (var stream = client.GetStream())
            using (var reader = new StreamReader(stream, Encoding.UTF8))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" })
            {
                string line;
                while (_running && (line = reader.ReadLine()) != null)
                {
                    if (string.IsNullOrWhiteSpace(line))
                        continue;

                    var pending = new Pending { RequestJson = line };
                    _queue.Enqueue(pending);

                    if (!pending.Response.Task.Wait(ResponseTimeoutMs))
                    {
                        writer.WriteLine("{\"ok\":false,\"error\":{\"code\":\"TIMEOUT\",\"message\":\"main thread did not respond\"}}");
                        continue;
                    }
                    writer.WriteLine(pending.Response.Task.Result);
                }
            }
        }

        private void OnDestroy()
        {
            _running = false;
            try { _listener?.Stop(); } catch { /* shutdown */ }
        }
    }
}


