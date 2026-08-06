using System;
using System.Collections;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Rendering;

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

        /// <summary>撮影中フラグ。**撮影が終わるまで後続コマンドを実行しない**（順序保証）。</summary>
        private bool _screenshotInFlight;

        private void Update()
        {
            if (_screenshotInFlight) return;   // 撮影完了までキューを進めない
            while (_queue.TryDequeue(out var pending))
            {
                // **スクリーンショットだけはフレーム終端を待つ**（Unity の画面キャプチャは
                // レンダリング完了後でないと正しい絵が取れない）。応答は TaskCompletionSource
                // なので、コルーチンから後で結果を入れれば呼び出し側はそのまま待てる
                if (CommandProcessor.TryPeek(pending.RequestJson, out var req, out var cmd) && cmd == "screenshot")
                {
                    // **撮影中は後続コマンドを進めない**。進めると、撮影要求のあとに来た tap 等が
                    // WaitForEndOfFrame より先に実行され、**要求時と違う画面を撮る**
                    // （「コマンド実行はメインスレッド直列」という約束も崩れる。レビュー指摘）。
                    // 2 件目以降の screenshot もキューで待ち、順に 1 件ずつ撮られる
                    _screenshotInFlight = true;
                    StartCoroutine(CaptureScreenshot(pending, req));
                    return;   // このフレームはここで打ち切り、残りは撮影完了後の Update で処理する
                }

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

        /// <summary>
        /// 画面を PNG で撮って base64 で返す（`screenshot` コマンド）。
        ///
        /// **プラットフォーム非依存のスクリーンショット手段**。adb screencap / simctl io /
        /// Unity CLI はそれぞれ Android・iOS シミュレータ・エディタでしか使えず、
        /// **iOS 実機にはどれも使えない**（iOS 17 以降、開発者サービスが lockdownd から外れ、
        /// libimobiledevice の screenshotr は Invalid service。pymobiledevice3 は特権が要る）。
        ///
        /// **アプリ内で撮る以上コストはゼロにできない。だから既定では使わない**
        /// （ドライバ側で明示的に有効化したときだけ呼ばれる）。実装として払える手は打ってある:
        ///   - `CaptureScreenshotIntoRenderTexture` ＋ `AsyncGPUReadback` で
        ///     **GPU パイプラインを同期待ちしない**（`CaptureScreenshotAsTexture` は
        ///     GPU→CPU の同期リードバックでフレームを止める）
        ///   - `maxWidth` で転送前に縮小できる（PNG エンコードは CPU コストで解像度に比例する）
        /// **残るコストは PNG エンコード（メインスレッド）と読み戻し帯域**で、
        /// **その大きさは実プロジェクトの描画負荷・解像度に依存する（サンプルでの計測は根拠にならない）**。
        ///
        /// args: maxWidth（省略可・0 以下なら等倍）
        /// </summary>
        private IEnumerator CaptureScreenshot(Pending pending, JObject req)
        {
            // **フラグ解除を取りこぼさない**（解除し損ねると Update がキューを進めなくなり、
            // ping を含む全コマンドがアプリ再起動まで応答不能になる）。
            // **ネストしたコルーチンにはしない** — 子で起きた例外は親の iterator を通らないため
            // 親の finally では回収できない（Unity の既知仕様。レビュー指摘）。
            // 単一 iterator にし、**すべての終了経路で必ず ReleaseScreenshotSlot を通す**
            var id = req["id"];
            var maxWidth = 0;
            try
            {
                var args = req["args"] as JObject;
                if (args?["maxWidth"] != null) maxWidth = (int)args["maxWidth"];
            }
            catch (Exception ex)
            {
                pending.Response.TrySetResult(
                    CommandProcessor.Failure(id, ErrorCodes.BadRequest, $"invalid args: {ex.Message}"));
                ReleaseScreenshotSlot();
                yield break;
            }

            // **yield は try の外**（C# は catch 付き try の中で yield できない）
            yield return new WaitForEndOfFrame();

            var width = Screen.width;
            var height = Screen.height;
            // **縮小は GPU 上（Blit）で済ませてから読み戻す**。読み戻した後に Texture2D.ReadPixels で
            // 縮小すると GPU の完了待ちが発生し、非同期化した意味が消える（Unity 公式が
            // ReadPixels は GPU 完了を待つと明記。レビュー指摘）
            if (maxWidth > 0 && width > maxWidth)
            {
                height = Mathf.Max(1, height * maxWidth / width);
                width = maxWidth;
            }
            RenderTexture rt = null;
            RenderTexture scaled = null;
            AsyncGPUReadbackRequest readback = default;
            var started = false;
            try
            {
                rt = RenderTexture.GetTemporary(Screen.width, Screen.height, 0,
                                                RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB);
                ScreenCapture.CaptureScreenshotIntoRenderTexture(rt);
                var source = rt;
                if (width != Screen.width)
                {
                    scaled = RenderTexture.GetTemporary(width, height, 0,
                                                        RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB);
                    Graphics.Blit(rt, scaled);   // GPU 上で縮小（CPU は待たない）
                    source = scaled;
                }
                readback = AsyncGPUReadback.Request(source, 0, TextureFormat.RGBA32);
                started = true;
            }
            catch (Exception ex)
            {
                if (scaled != null) RenderTexture.ReleaseTemporary(scaled);
                if (rt != null) RenderTexture.ReleaseTemporary(rt);
                pending.Response.TrySetResult(
                    CommandProcessor.Failure(id, ErrorCodes.Internal, $"screenshot failed: {ex.Message}"));
            }
            if (!started)
            {
                ReleaseScreenshotSlot();
                yield break;
            }

            // **読み戻しの完了はフレームをまたいで待つ**（ここで待ってもレンダリングは止まらない）
            while (!readback.done)
                yield return null;

            string response;
            try
            {
                if (readback.hasError)
                {
                    response = CommandProcessor.Failure(id, ErrorCodes.Internal,
                        "screenshot failed: GPU readback error");
                }
                else
                {
                    var tex = new Texture2D(width, height, TextureFormat.RGBA32, false);
                    try
                    {
                        tex.LoadRawTextureData(readback.GetData<byte>());
                        tex.Apply(false);
                        // CaptureScreenshotIntoRenderTexture は下から上へ書くため、
                        // そのままだと上下反転する（グラフィックス API に依らずこの向き）
                        // **同時にアルファを不透明へ潰す**。読み戻したバッファのアルファは
                        // カメラのクリア設定や描画パイプライン次第で 0 や中途半端な値になり得て、
                        // **そのまま PNG にすると画像が丸ごと透明＝見えない証跡になる**。
                        // その失敗は「撮れているのに何も写っていない」形で現れ、原因が分かりにくい。
                        // **この 3 サンプルでは元から全画素 255 だった**（PNG を解析して実測）ので、
                        // ここは実測で必要になった処理ではなく、上の失敗を避けるための保険。
                        // なお**半透明 UI の見え方は画面と一致する** — 画面に出ている合成結果を
                        // 撮っているので、UI 自身の透明度は既に色へ焼き込まれている
                        FlipAndMakeOpaque(tex);

                        var png = tex.EncodeToPNG();
                        response = CommandProcessor.Success(id, new JObject
                        {
                            ["format"] = "png",
                            ["width"] = tex.width,
                            ["height"] = tex.height,
                            ["bytes"] = png.Length,
                            ["base64"] = Convert.ToBase64String(png)
                        });
                    }
                    finally
                    {
                        Destroy(tex);
                    }
                }
            }
            catch (Exception ex)
            {
                response = CommandProcessor.Failure(id, ErrorCodes.Internal, $"screenshot failed: {ex.Message}");
            }
            finally
            {
                if (scaled != null) RenderTexture.ReleaseTemporary(scaled);
                RenderTexture.ReleaseTemporary(rt);
                ReleaseScreenshotSlot();
            }
            pending.Response.TrySetResult(response);
        }

        /// <summary>撮影スロットを解放して Update のキュー処理を再開させる。</summary>
        private void ReleaseScreenshotSlot()
        {
            _screenshotInFlight = false;
        }

        /// <summary>上下反転とアルファの不透明化（画面に見えているとおりの PNG にする）。</summary>
        private static void FlipAndMakeOpaque(Texture2D tex)
        {
            var pixels = tex.GetPixels32();
            var flipped = new Color32[pixels.Length];
            var w = tex.width;
            for (var y = 0; y < tex.height; y++)
                Array.Copy(pixels, y * w, flipped, (tex.height - 1 - y) * w, w);
            for (var i = 0; i < flipped.Length; i++)
                flipped[i].a = 255;
            tex.SetPixels32(flipped);
            tex.Apply(false);
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


