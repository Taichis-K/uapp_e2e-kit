using System;

namespace E2EBridge
{
    /// <summary>
    /// プロトコルエラー。code はクライアントが機械的に分岐できる識別子。
    /// </summary>
    public class BridgeException : Exception
    {
        public string Code { get; }

        public BridgeException(string code, string message) : base(message)
        {
            Code = code;
        }
    }

    public static class ErrorCodes
    {
        public const string UnknownCommand = "UNKNOWN_COMMAND";
        public const string BadRequest = "BAD_REQUEST";
        public const string NotFound = "NOT_FOUND";
        public const string Ambiguous = "AMBIGUOUS";
        public const string PointerAlreadyDown = "POINTER_ALREADY_DOWN";
        public const string PointerNotDown = "POINTER_NOT_DOWN";
        public const string NguiNotPresent = "NGUI_NOT_PRESENT";
        // uGUI へイベントを送る先が無い。シーンに EventSystem が居ないか、読み込みが終わっていない
        public const string NoEventSystem = "NO_EVENTSYSTEM";
        public const string AlreadyPressed = "ALREADY_PRESSED";
        public const string NotPressed = "NOT_PRESSED";
        // レガシー入力バックエンドでは Input System への注入が届かない。
        // 黙って何も起きないと、AI はアプリのバグを疑って延々と調べることになる
        public const string InputBackendLegacy = "INPUT_BACKEND_LEGACY";
        // Input System **パッケージ自体が入っていない**。バックエンドが無効（INPUT_BACKEND_LEGACY）とは別物で、
        // 直し方も違う（前者はパッケージ導入、後者は Active Input Handling の変更）
        public const string InputSystemNotPresent = "INPUT_SYSTEM_NOT_PRESENT";
        public const string Internal = "INTERNAL";
    }
}

#if !(UAPP_E2E_INPUTSYSTEM && ENABLE_INPUT_SYSTEM)
namespace E2EBridge
{
    /// <summary>
    /// Input System への注入が**このビルドでは成立しない**ときの、共通の断り方。
    ///
    /// <para>計装のうち Input System を要るのは 3 ファイル（TouchInjector / DeviceInjector /
    /// EditorInputRouting）だけで、**dump / resolve / hittable / ugui_event / ngui_event は要らない**。
    /// レガシー Input のプロジェクトへ「動かない 3 ファイルのためだけに」パッケージ導入を強いていたので、
    /// 入っていなくてもコンパイルできる形にした（`ENABLE_INPUT_SYSTEM` が無いときはこちらが入る）。</para>
    ///
    /// <para>**黙って無効にしない**。黙ると呼び手はアプリのバグを疑って延々と調べる。
    /// 理由（パッケージ不在か、バックエンド無効か）で**直し方が違う**ので、区別して返す。</para>
    /// </summary>
    internal static class InputBackendUnavailable
    {
        public static BridgeException For(string what)
        {
#if UAPP_E2E_INPUTSYSTEM
            return new BridgeException(ErrorCodes.InputBackendLegacy,
                $"{what}は Input System への注入なので、この構成では届きません" +
                "（Player Settings の Active Input Handling が 'Input Manager (Old)' のみ）。" +
                "使いたい場合は 'Input System Package' か 'Both' へ変更してください。" +
                "UI の操作だけなら変更は不要です（uGUI は ugui_event / NGUI は ngui_event を使う）");
#else
            return new BridgeException(ErrorCodes.InputSystemNotPresent,
                $"{what}は Input System への注入なので、このプロジェクトでは使えません" +
                "（com.unity.inputsystem が入っていません）。" +
                "使いたい場合はパッケージを追加し、Active Input Handling を 'Input System Package' か 'Both' へ。" +
                "UI の操作だけなら追加は不要です（uGUI は ugui_event / NGUI は ngui_event を使う）");
#endif
        }
    }
}
#endif
