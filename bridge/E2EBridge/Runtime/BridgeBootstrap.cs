using UnityEngine;

namespace E2EBridge
{
    /// <summary>
    /// UAPP_E2E_BRIDGE define が有効なビルドでのみ、起動時に自動でブリッジを立ち上げる。
    /// シーンへの配置は不要（既存アプリへは define を足すだけで導入できる）。
    /// </summary>
    public static class BridgeBootstrap
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void Init()
        {
#if UNITY_2023_1_OR_NEWER
            if (Object.FindFirstObjectByType<BridgeHost>() != null)
                return;
#else
            if (Object.FindObjectOfType<BridgeHost>() != null)
                return;
#endif

            var go = new GameObject("[E2EBridge]");
            Object.DontDestroyOnLoad(go);
            go.AddComponent<BridgeHost>();
        }
    }
}

