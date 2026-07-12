using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace E2EBridge.Editor
{
    /// <summary>
    /// 導入先プロジェクト向けの汎用 E2E ビルドエントリ（計装入りAPK）。
    /// 自前のビルドパイプラインを持つプロジェクトは、そちらへ UAPP_E2E_BRIDGE define を
    /// 組み込む形でもよい（本エントリは「ビルドスクリプトの用意がないプロジェクト」向けの既定経路）。
    ///
    /// 変更する設定（ProjectSettings に永続化される。VCS の差分で確認・復元できる）:
    ///   - Scripting Define Symbols(Android): UAPP_E2E_BRIDGE を付与（-release 時は除去）
    ///   - グラフィックスAPI(Android): GLES3 強制（エミュレーターの Vulkan は開発ビルドでクラッシュする。実機でも安全）
    ///   - ターゲットアーキテクチャ(Android): 既定 ARM64+X86_64（実機・エミュレーター両対応）。
    ///     APKサイズを絞る場合は -buildArch ARM64 / X86_64 で単一指定（変更前の値はログに出力）
    /// 変更しない設定: applicationIdentifier / 画面向き / scripting backend / シーン一覧
    /// </summary>
    public static class BuildEntry
    {
        private const string BridgeDefine = "UAPP_E2E_BRIDGE";

        public static void BuildAndroid()
        {
            var output = GetArg("-buildOutput") ?? "uapp_e2e/Builds/e2e.apk";
            var release = HasArg("-release");
            var target = NamedBuildTarget.Android;

            var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
            if (scenes.Length == 0)
            {
                Debug.LogError("[E2EBridge.BuildEntry] EditorBuildSettings に有効なシーンがありません");
                EditorApplication.Exit(1);
                return;
            }

            // エミュレーターの Vulkan 実装は開発ビルドでクラッシュするため GLES3 を強制
            var oldApis = PlayerSettings.GetGraphicsAPIs(BuildTarget.Android);
            PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.Android, false);
            PlayerSettings.SetGraphicsAPIs(BuildTarget.Android,
                new[] { UnityEngine.Rendering.GraphicsDeviceType.OpenGLES3 });

            var oldArch = PlayerSettings.Android.targetArchitectures;
            PlayerSettings.Android.targetArchitectures = ParseArch(GetArg("-buildArch"));

            SetDefine(target, BridgeDefine, enabled: !release);

            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output)) ?? ".");

            var options = new BuildPlayerOptions
            {
                scenes = scenes,
                target = BuildTarget.Android,
                locationPathName = output,
                options = release ? BuildOptions.None : BuildOptions.Development
            };

            var report = BuildPipeline.BuildPlayer(options);
            var summary = report.summary;
            Debug.Log($"[E2EBridge.BuildEntry] result={summary.result} errors={summary.totalErrors} " +
                      $"output={output} bridge={(release ? "OFF" : "ON")} " +
                      $"graphicsAPIs(before)={string.Join(",", oldApis)} arch(before)={oldArch}");

            if (summary.result != BuildResult.Succeeded)
                EditorApplication.Exit(1);
        }

        /// <summary>-buildArch の解釈。未指定は実機(ARM64)・エミュレーター(X86_64)両対応の同梱。</summary>
        private static AndroidArchitecture ParseArch(string value)
        {
            switch (value?.ToUpperInvariant())
            {
                case "ARM64":  return AndroidArchitecture.ARM64;
                case "X86_64": return AndroidArchitecture.X86_64;
                case null:
                case "":       return AndroidArchitecture.ARM64 | AndroidArchitecture.X86_64;
                default:
                    Debug.LogWarning($"[E2EBridge.BuildEntry] 未知の -buildArch '{value}' は既定(ARM64+X86_64)にフォールバック");
                    return AndroidArchitecture.ARM64 | AndroidArchitecture.X86_64;
            }
        }

        private static void SetDefine(NamedBuildTarget target, string define, bool enabled)
        {
            var defines = PlayerSettings.GetScriptingDefineSymbols(target)
                .Split(';', StringSplitOptions.RemoveEmptyEntries)
                .ToList();
            if (enabled && !defines.Contains(define)) defines.Add(define);
            if (!enabled) defines.Remove(define);
            PlayerSettings.SetScriptingDefineSymbols(target, string.Join(";", defines));
        }

        private static string GetArg(string name)
        {
            var args = Environment.GetCommandLineArgs();
            for (var i = 0; i < args.Length - 1; i++)
                if (args[i] == name)
                    return args[i + 1];
            return null;
        }

        private static bool HasArg(string name) => Environment.GetCommandLineArgs().Contains(name);
    }
}
