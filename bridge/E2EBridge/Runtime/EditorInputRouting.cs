using UnityEngine;
using UnityEngine.InputSystem;
#if UNITY_EDITOR
using UnityEditor;
#endif

namespace E2EBridge
{
    /// <summary>
    /// エディタ再生専用: Game view が非フォーカスでも、注入した入力が「player の更新」で
    /// 処理されるようにする（デバイスビルドでは何もしない）。
    ///
    /// <para>Input System の既定設定（editorInputBehaviorInPlayMode =
    /// PointersAndKeyboardsRespectGameViewFocus）では、Game view が非フォーカスの間、
    /// Pointer / Keyboard のイベントは **Editor 更新でのみ**処理される。アクション駆動の UI
    /// （InputSystemUIInputModule）は Editor 更新でも発火するため一見正常に見えるが、
    /// `wasPressedThisFrame` 等のポーリング API のエッジは player 更新のフレームに立たず、
    /// デバイスを直読みするゲームコードには入力が一切届かない。エディタを前面に出さずに
    /// E2E を回す運用（導入先の実運用）で実際に起きた。</para>
    ///
    /// <para>**ここでの「非フォーカス」は OS のウィンドウフォーカスではない**。Unity の
    /// ウィンドウを最小化しても他アプリを前面にしても `Application.isFocused` は true のままで、
    /// エディタ内で Game view が別のビュー（Scene view 等）へフォーカスを奪われたときだけ
    /// false になる（Unity 6000.3.6f1 で実測）。</para>
    ///
    /// <para>そのため最初の注入時に次の 3 点セットへ切り替える。3 つ揃って初めて
    /// 「非フォーカスでも全イベントが player 更新で処理される」状態になる
    /// （Input System 1.18.0 の InputManager.OnUpdate / ShouldFlushEventBuffer で確認）:</para>
    /// <list type="bullet">
    /// <item>editorInputBehaviorInPlayMode = AllDeviceInputAlwaysGoesToGameView
    ///   （Pointer / Keyboard を Editor 更新へ回す振り分けをやめる）</item>
    /// <item>backgroundBehavior = IgnoreFocus
    ///   （フォーカス喪失でデバイスが無効化されるのを防ぐ）</item>
    /// <item>Application.runInBackground = true
    ///   （false のままだと AllDeviceInputAlwaysGoesToGameView は非フォーカス時に
    ///   イベントバッファを**破棄**する）</item>
    /// </list>
    ///
    /// <para>適用は「最初の注入時」まで遅延させる: 人がエディタで普通に再生して開発している間は
    /// 何も変えない（このオーバーライドは実マウス・実キーボードの入力も常に Game view へ
    /// 届けるため、注入が始まるまで有効にしない）。再生終了時に元の値へ戻し、
    /// プロジェクトの設定を汚さない。</para>
    /// </summary>
    internal static class EditorInputRouting
    {
#if UNITY_EDITOR
        // **元の値は SessionState に置く**（静的フィールドだけだと、再生中のスクリプト再読み込みで
        // 消え、「上書き後の値」を元の値として記録してしまう＝復元が効かなくなる）。
        // SessionState はドメインリロードを跨ぎ、エディタを閉じれば消えるので、この用途に合う
        private const string KeyApplied = "uapp_e2e.inputRouting.applied";
        private const string KeyEditorBehavior = "uapp_e2e.inputRouting.prevEditorBehavior";
        private const string KeyBackgroundBehavior = "uapp_e2e.inputRouting.prevBackgroundBehavior";
        private const string KeyRunInBackground = "uapp_e2e.inputRouting.prevRunInBackground";

        /// <summary>オーバーライド適用中か（input_devices で外から見えるようにする）。</summary>
        public static bool Applied => SessionState.GetBool(KeyApplied, false);

        // ドメインリロードでイベント購読は切れる。復活させないと再生終了時に復元されず、
        // 上書きしたままエディタに残る
        [InitializeOnLoadMethod]
        private static void ResubscribeAfterDomainReload()
        {
            if (Applied)
                Subscribe();
        }

        private static void Subscribe()
        {
            EditorApplication.playModeStateChanged -= OnPlayModeStateChanged;
            EditorApplication.playModeStateChanged += OnPlayModeStateChanged;
        }

        /// <summary>注入イベントの直前に呼ぶ。初回だけ設定を切り替える（以降は no-op）。</summary>
        public static void EnsureGameViewRouting()
        {
            if (Applied)
                return;

            var settings = InputSystem.settings;
            SessionState.SetInt(KeyEditorBehavior, (int)settings.editorInputBehaviorInPlayMode);
            SessionState.SetInt(KeyBackgroundBehavior, (int)settings.backgroundBehavior);
            SessionState.SetBool(KeyRunInBackground, Application.runInBackground);
            SessionState.SetBool(KeyApplied, true);

            settings.editorInputBehaviorInPlayMode =
                InputSettings.EditorInputBehaviorInPlayMode.AllDeviceInputAlwaysGoesToGameView;
            settings.backgroundBehavior = InputSettings.BackgroundBehavior.IgnoreFocus;
            Application.runInBackground = true;

            // 切り替え**前**の非フォーカス期間に、旧設定（ResetAndDisableNonBackgroundDevices）が
            // 無効化したデバイスを起こす。IgnoreFocus へ切り替えた後はフォーカス復帰でも
            // 再有効化されないので、ここで戻すしかない
            DeviceInjector.RepairDisabledDevices();

            Subscribe();
            Debug.Log("[E2EBridge] エディタ入力ルーティングを上書き: Game view が非フォーカスでも" +
                      "注入入力を player 更新で処理する（再生終了時に元の設定へ戻す）");
        }

        private static void OnPlayModeStateChanged(PlayModeStateChange change)
        {
            if (change != PlayModeStateChange.ExitingPlayMode)
                return;
            EditorApplication.playModeStateChanged -= OnPlayModeStateChanged;
            if (!Applied)
                return;

            // 設定は再生をまたいで残るので、必ず元の値へ戻す
            var settings = InputSystem.settings;
            settings.editorInputBehaviorInPlayMode =
                (InputSettings.EditorInputBehaviorInPlayMode)SessionState.GetInt(
                    KeyEditorBehavior,
                    (int)InputSettings.EditorInputBehaviorInPlayMode.PointersAndKeyboardsRespectGameViewFocus);
            settings.backgroundBehavior =
                (InputSettings.BackgroundBehavior)SessionState.GetInt(
                    KeyBackgroundBehavior,
                    (int)InputSettings.BackgroundBehavior.ResetAndDisableNonBackgroundDevices);
            Application.runInBackground = SessionState.GetBool(KeyRunInBackground, false);

            SessionState.EraseBool(KeyApplied);
            SessionState.EraseInt(KeyEditorBehavior);
            SessionState.EraseInt(KeyBackgroundBehavior);
            SessionState.EraseBool(KeyRunInBackground);
        }
#else
        public static bool Applied => false;

        public static void EnsureGameViewRouting()
        {
        }
#endif
    }
}
