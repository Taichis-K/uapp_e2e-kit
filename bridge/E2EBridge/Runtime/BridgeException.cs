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
        public const string Internal = "INTERNAL";
    }
}
