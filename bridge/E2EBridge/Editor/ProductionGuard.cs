using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace E2EBridge.EditorTools
{
    /// <summary>
    /// **本番ビルドへ計装が混ざるのを止める**（issue #63）。
    ///
    /// <para>計装は `UAPP_E2E_BRIDGE` define のときだけ有効になるが、
    /// **自前のビルドスクリプトを使う構成では define を恒久付与することがある**
    /// （毎回付け外しするより現実的なため。installer もそのとき `[注意]` を出す）。
    /// その場合、**本番ビルドにも計装が入りうる**。</para>
    ///
    /// <para>**既定では何もしない。** `e2e-config.json` に `productionGuard.devDefine` を
    /// 書いたプロジェクトでだけ有効になる ―
    /// **キットが導入先のビルドへ勝手に割り込まないため**。
    /// 止める仕組みは、**外し方が分からないと本番リリースを止めてしまう**ので、
    /// 環境変数 `UAPP_E2E_SKIP_PRODUCTION_GUARD=1` でいつでも無効化できる。</para>
    ///
    /// <para>**判定は <see cref="Check"/> の純関数**に分けてある（EditMode で検証するため）。</para>
    /// </summary>
    public class ProductionGuard : IPreprocessBuildWithReport
    {
        public const string BridgeDefine = "UAPP_E2E_BRIDGE";
        public const string SkipEnvVar = "UAPP_E2E_SKIP_PRODUCTION_GUARD";

        public int callbackOrder => 0;

        public void OnPreprocessBuild(BuildReport report)
        {
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable(SkipEnvVar))) return;

            var devDefine = ReadDevDefine();
            if (string.IsNullOrEmpty(devDefine)) return;   // 設定していないプロジェクトでは無効

            var named = NamedBuildTarget.FromBuildTargetGroup(report.summary.platformGroup);
            var symbols = PlayerSettings.GetScriptingDefineSymbols(named)
                .Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(s => s.Trim())
                .ToArray();

            var problem = Check(symbols, devDefine);
            if (problem != null) throw new BuildFailedException(problem);
        }

        /// <summary>
        /// **問題があればメッセージ、無ければ null。** 呼ぶ側の状態に依存しない純関数。
        ///
        /// <para>止めるのは「**計装は入るのに、開発版の目印が無い**」ときだけ。
        /// 計装が入らないビルド（define なし）は本番でも開発でも素通しする ―
        /// **ここで欲を出して他の条件も裁くと、誤検知でリリースを止める側になる**。</para>
        /// </summary>
        public static string Check(string[] symbols, string devDefine)
        {
            if (string.IsNullOrEmpty(devDefine)) return null;
            if (symbols == null) symbols = new string[0];
            if (!symbols.Contains(BridgeDefine)) return null;   // 計装が入らない＝問題なし
            if (symbols.Contains(devDefine)) return null;       // 開発版＝問題なし

            return
                "本番ビルドに E2E 計装が混ざります。" +
                "\n  " + BridgeDefine + " が付いているのに、開発版の目印 '" + devDefine + "' がありません。" +
                "\n  現在の define: " + (symbols.Length > 0 ? string.Join(", ", symbols) : "(なし)") +
                "\n" +
                "\n  直し方は 2 つ:" +
                "\n    a) 本番ビルドなら " + BridgeDefine + " を外す（計装を入れない）" +
                "\n    b) 開発版ビルドなら '" + devDefine + "' を付ける" +
                "\n" +
                "\n  この検査は e2e-config.json の productionGuard.devDefine を設定したときだけ動きます。" +
                "\n  一時的に外すなら環境変数 " + SkipEnvVar + "=1（この判断は記録に残らないので、常用しないこと）";
        }

        /// <summary>`e2e-config.json` の `productionGuard.devDefine`。無ければ null。</summary>
        private static string ReadDevDefine()
        {
            // サンプル配置（プロジェクト直下）→ 導入キット配置（uapp_e2e/ 内）の順。BridgeHost と同じ探索
            var candidates = new[]
            {
                Path.Combine(Application.dataPath, "..", "e2e-config.json"),
                Path.Combine(Application.dataPath, "..", "uapp_e2e", "e2e-config.json")
            };
            foreach (var path in candidates)
            {
                if (!File.Exists(path)) continue;
                try
                {
                    // **JsonUtility を使う**（Newtonsoft への依存を増やさない ―
                    // レガシー構成では入れていないことがある）。未知のフィールドは無視される
                    var root = JsonUtility.FromJson<ConfigRoot>(File.ReadAllText(path));
                    var value = root?.productionGuard?.devDefine;
                    if (!string.IsNullOrEmpty(value)) return value.Trim();
                }
                catch (Exception e)
                {
                    // **設定を読めないことでビルドを止めない。** ガードは保険であって、
                    // それ自体がリリースを妨げる理由にはしない
                    Debug.LogWarning("[E2EBridge] productionGuard の設定を読めませんでした（無効のまま続行）: " + e.Message);
                }
            }
            return null;
        }

        [Serializable] private class ConfigRoot { public ProductionGuardConfig productionGuard; }
        [Serializable] private class ProductionGuardConfig { public string devDefine; }
    }
}
