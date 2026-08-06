using System;
using System.Collections.Generic;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace E2EBridge
{
    /// <summary>
    /// NGUI へのリフレクションアダプタ。
    /// NGUI は有料アセットのためこのリポジトリには含まれない。コンパイル時依存を持たず、
    /// NGUI が存在するプロジェクトへコピーされたとき実行時に自動で有効化される。
    ///
    /// 対象 API（複数の実プロジェクトの NGUI ソースで確認済み）:
    ///   UICamera.Raycast(Vector3) : bool   … 全UICameraを対象にしたヒットテスト
    ///   UICamera.mRayHitObject (private static) … Raycast が設定するヒット結果（2D/3D両対応）
    ///   UICamera.hoveredObject (public static)  … フォールバック
    ///   UICamera.Notify(GameObject, string, object) … OnPress/OnClick 等のイベント送出
    ///   UICamera.FindCameraForLayer(int) / .cachedCamera
    ///   UIWidget.worldCorners / UIRoot / UIButton.isEnabled
    /// </summary>
    public static class NguiAdapter
    {
        private static bool _initialized;
        private static Type _uiCamera, _uiWidget, _uiRoot, _uiButton;
        private static MethodInfo _raycast, _notify, _findCameraForLayer;
        private static FieldInfo _rayHitField;
        private static PropertyInfo _hoveredProp, _worldCornersProp, _cachedCameraProp, _isEnabledProp;

        public static bool Available
        {
            get { Init(); return _uiCamera != null && _raycast != null && _notify != null; }
        }

        private static void Init()
        {
            if (_initialized) return;
            _initialized = true;

            _uiCamera = FindType("UICamera");
            if (_uiCamera == null) return;
            _uiWidget = FindType("UIWidget");
            _uiRoot = FindType("UIRoot");
            _uiButton = FindType("UIButton");

            _raycast = _uiCamera.GetMethod("Raycast", BindingFlags.Public | BindingFlags.Static,
                null, new[] { typeof(Vector3) }, null);
            _notify = _uiCamera.GetMethod("Notify", BindingFlags.Public | BindingFlags.Static,
                null, new[] { typeof(GameObject), typeof(string), typeof(object) }, null);
            _findCameraForLayer = _uiCamera.GetMethod("FindCameraForLayer", BindingFlags.Public | BindingFlags.Static,
                null, new[] { typeof(int) }, null);
            _rayHitField = _uiCamera.GetField("mRayHitObject", BindingFlags.NonPublic | BindingFlags.Static);
            _hoveredProp = _uiCamera.GetProperty("hoveredObject", BindingFlags.Public | BindingFlags.Static);
            _worldCornersProp = _uiWidget?.GetProperty("worldCorners", BindingFlags.Public | BindingFlags.Instance);
            _cachedCameraProp = _uiCamera.GetProperty("cachedCamera", BindingFlags.Public | BindingFlags.Instance);
            _isEnabledProp = _uiButton?.GetProperty("isEnabled", BindingFlags.Public | BindingFlags.Instance);
        }

        private static Type FindType(string name)
        {
            foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
            {
                var type = assembly.GetType(name);
                if (type != null) return type;
            }
            return null;
        }

        private static UnityEngine.Object[] FindAll(Type type)
        {
#if UNITY_2023_1_OR_NEWER
            return UnityEngine.Object.FindObjectsByType(type, FindObjectsInactive.Include, FindObjectsSortMode.None);
#else
            return UnityEngine.Object.FindObjectsOfType(type, true);
#endif
        }

        // ------------------------------------------------------------- 階層

        /// <summary>dump のルートに加える NGUI ツリー（UIRoot、無ければ UICamera のルート）。</summary>
        public static IEnumerable<Transform> FindRoots()
        {
            if (!Available) yield break;
            var rootType = _uiRoot ?? _uiCamera;
            var seen = new HashSet<Transform>();
            foreach (var obj in FindAll(rootType))
            {
                if (!(obj is Component comp) || !comp.gameObject.scene.isLoaded) continue;
                var root = _uiRoot != null ? comp.transform : comp.transform.root;
                if (seen.Add(root)) yield return root;
            }
        }

        public static bool HasCollider(GameObject go) =>
            go.GetComponent<Collider>() != null || go.GetComponent<Collider2D>() != null;

        /// <summary>
        /// NGUI ウィジェットのスクリーン座標矩形（Unity座標系: 左下原点）。
        /// UIWidget.worldCorners を優先し、コライダーのみのタッチ領域は bounds から算出。
        /// </summary>
        public static bool TryGetScreenRect(GameObject go, out Rect rect)
        {
            rect = default;
            if (!Available) return false;

            Vector3[] worldPoints = null;
            var widget = _uiWidget != null ? go.GetComponent(_uiWidget) : null;
            if (widget != null && _worldCornersProp != null)
                worldPoints = _worldCornersProp.GetValue(widget) as Vector3[];

            if (worldPoints == null)
            {
                Bounds bounds;
                var collider = go.GetComponent<Collider>();
                if (collider != null) bounds = collider.bounds;
                else
                {
                    var collider2d = go.GetComponent<Collider2D>();
                    if (collider2d == null) return false;
                    bounds = collider2d.bounds;
                }
                worldPoints = new[]
                {
                    bounds.min,
                    new Vector3(bounds.min.x, bounds.max.y, bounds.center.z),
                    bounds.max,
                    new Vector3(bounds.max.x, bounds.min.y, bounds.center.z)
                };
            }

            var cam = CameraFor(go);
            if (cam == null) return false;

            var min = new Vector2(float.MaxValue, float.MaxValue);
            var max = new Vector2(float.MinValue, float.MinValue);
            foreach (var world in worldPoints)
            {
                Vector3 screenPoint = cam.WorldToScreenPoint(world);
                min = Vector2.Min(min, screenPoint);
                max = Vector2.Max(max, screenPoint);
            }
            rect = new Rect(min, max - min);
            return true;
        }

        private static Camera CameraFor(GameObject go)
        {
            if (_findCameraForLayer != null)
            {
                if (_findCameraForLayer.Invoke(null, new object[] { go.layer }) is Component uiCam)
                {
                    if (_cachedCameraProp?.GetValue(uiCam) is Camera cached) return cached;
                    var direct = uiCam.GetComponent<Camera>();
                    if (direct != null) return direct;
                }
            }
            return Camera.main;
        }

        /// <summary>UIButton.isEnabled。UIButton が無いオブジェクトは null。</summary>
        public static bool? Interactable(GameObject go)
        {
            if (!Available || _uiButton == null || _isEnabledProp == null) return null;
            var button = go.GetComponent(_uiButton);
            if (button == null) return null;
            return _isEnabledProp.GetValue(button) as bool?;
        }

        // ------------------------------------------------------------- probe

        /// <summary>
        /// 実ユーザーのタッチがこのオブジェクトに届くかを NGUI 自身のヒットテスト
        /// （UICamera.Raycast: コライダーへの Physics レイキャスト、2D/3D 両対応）で判定する。
        /// NGUI はコライダー（イベント受け手）とウィジェット（見た目）が親子に分かれる構成が
        /// 多いため、ヒット結果と対象の祖先・子孫関係を双方向で許容する。
        /// </summary>
        // blocker の意味は RaycastProbe.Probe と同じ（blockedBy がパスのときだけ非 null）
        public static (bool hittable, string blockedBy, GameObject blocker) Probe(GameObject target, Vector2 screenPos)
        {
            if (!Available) return (false, "NGUI_NOT_PRESENT", null);

            var hit = (bool)_raycast.Invoke(null, new object[] { new Vector3(screenPos.x, screenPos.y, 0f) });
            if (!hit) return (false, "NOTHING_HIT", null);

            var hitGo = _rayHitField?.GetValue(null) as GameObject;
            if (hitGo == null && _hoveredProp != null)
                hitGo = _hoveredProp.GetValue(null) as GameObject;
            if (hitGo == null) return (false, "NGUI_HIT_UNKNOWN", null);

            if (hitGo.transform == target.transform ||
                hitGo.transform.IsChildOf(target.transform) ||
                target.transform.IsChildOf(hitGo.transform))
                return (true, null, null);

            return (false, HierarchyDumper.GetPath(hitGo.transform), hitGo);
        }

        // ------------------------------------------------------------- event

        /// <summary>
        /// ngui_event コマンド。UICamera.Notify によるフレームワークレベルのイベント送出。
        /// レガシー Input 構成の NGUI アプリ（Touchscreen 注入が届かない）向け。
        /// 到達可能性の検証は行わない（クライアント側が resolve の hittable で事前検証する規約）。
        /// </summary>
        public static JToken HandleEvent(JObject args)
        {
            if (!Available)
                throw new BridgeException(ErrorCodes.NguiNotPresent, "NGUI (UICamera) is not present in this build");

            var path = (string)args["path"]
                       ?? throw new BridgeException(ErrorCodes.BadRequest, "'path' is required");
            var eventName = (string)args["event"] ?? "click";
            var go = HierarchyDumper.Require(path);

            switch (eventName)
            {
                case "click":
                    Notify(go, "OnPress", true);
                    Notify(go, "OnPress", false);
                    Notify(go, "OnClick", null);
                    break;
                case "press":
                    Notify(go, "OnPress", true);
                    break;
                case "release":
                    Notify(go, "OnPress", false);
                    break;
                default:
                    throw new BridgeException(ErrorCodes.BadRequest,
                        $"unknown event: '{eventName}' (click | press | release)");
            }

            return new JObject
            {
                ["path"] = HierarchyDumper.GetPath(go.transform),
                ["event"] = eventName
            };
        }

        private static void Notify(GameObject go, string funcName, object arg) =>
            _notify.Invoke(null, new object[] { go, funcName, arg });
    }
}
