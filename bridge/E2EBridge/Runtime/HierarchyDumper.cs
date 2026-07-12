using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.SceneManagement;
using UnityEngine.UI;

namespace E2EBridge
{
    /// <summary>
    /// UI 階層のダンプ・オブジェクト解決・プロパティ取得。
    /// dump が返す JSON は AI がテストを書くための「地図」なので、
    /// 位置・テキスト・到達可能性(hittable)を人間可読な形で含める。
    /// </summary>
    public static class HierarchyDumper
    {
        // ---------------------------------------------------------------- dump

        public static JToken Dump(JObject args)
        {
            var scope = (string)args["scope"] ?? "ui";
            var probe = (string)args["probe"] ?? "selectable"; // none | selectable | all
            var rootPath = (string)args["path"];

            var roots = new List<Transform>();
            if (!string.IsNullOrEmpty(rootPath))
            {
                roots.Add(Require(rootPath).transform);
            }
            else if (scope == "ui")
            {
                roots.AddRange(FindAll<Canvas>()
                    .Where(c => c.isRootCanvas)
                    .OrderBy(c => c.sortingOrder)
                    .Select(c => c.transform));
                // NGUI ツリー（存在する場合のみ）
                roots.AddRange(NguiAdapter.FindRoots().Where(r => !roots.Contains(r)));
            }
            else // "all"
            {
                for (var i = 0; i < SceneManager.sceneCount; i++)
                {
                    var scene = SceneManager.GetSceneAt(i);
                    if (scene.isLoaded)
                        roots.AddRange(scene.GetRootGameObjects().Select(g => g.transform));
                }
            }

            var nodes = new JArray();
            foreach (var root in roots)
                nodes.Add(DumpNode(root, probe));

            return new JObject
            {
                ["screen"] = new JObject { ["w"] = Screen.width, ["h"] = Screen.height },
                ["scene"] = SceneManager.GetActiveScene().name,
                ["nodes"] = nodes
            };
        }

        private static JToken DumpNode(Transform t, string probe)
        {
            var go = t.gameObject;
            var node = new JObject
            {
                ["name"] = go.name,
                ["path"] = GetPath(t),
                ["active"] = go.activeInHierarchy,
                ["components"] = new JArray(go.GetComponents<Component>()
                    .Where(c => c != null)
                    .Select(c => c.GetType().Name))
            };

            Rect? screenRect = null;
            var isNgui = false;
            if (t is RectTransform rt)
            {
                screenRect = ScreenRect(rt);
            }
            else if (NguiAdapter.TryGetScreenRect(go, out var nguiRect))
            {
                screenRect = nguiRect;
                isNgui = true;
                node["ui"] = "ngui";
            }
            if (screenRect is Rect r)
            {
                node["rect"] = new JObject { ["x"] = r.x, ["y"] = r.y, ["w"] = r.width, ["h"] = r.height };
                node["center"] = new JObject { ["x"] = r.center.x, ["y"] = r.center.y };
            }

            var text = ExtractText(go);
            if (text != null)
                node["text"] = text;

            var selectable = go.GetComponent<Selectable>();
            if (selectable != null)
                node["interactable"] = selectable.IsInteractable();

            var graphic = go.GetComponent<Graphic>();
            if (graphic != null)
                node["raycastTarget"] = graphic.raycastTarget;

            var nguiInteractable = isNgui ? NguiAdapter.Interactable(go) : null;
            if (nguiInteractable != null)
                node["interactable"] = nguiInteractable.Value;

            // NGUI のクリック可能要素 = コライダー持ち（uGUI の Selectable 相当）
            var clickable = selectable != null || (isNgui && NguiAdapter.HasCollider(go));
            var shouldProbe = probe == "all" || (probe == "selectable" && clickable);
            if (shouldProbe && go.activeInHierarchy && screenRect is Rect pr)
            {
                var (hittable, blockedBy) = isNgui
                    ? NguiAdapter.Probe(go, pr.center)
                    : RaycastProbe.Probe(go, pr.center);
                node["hittable"] = hittable;
                if (blockedBy != null)
                    node["blockedBy"] = blockedBy;
            }

            if (t.childCount > 0)
            {
                var children = new JArray();
                for (var i = 0; i < t.childCount; i++)
                    children.Add(DumpNode(t.GetChild(i), probe));
                node["children"] = children;
            }

            return node;
        }

        // ------------------------------------------------------------- resolve

        public static JToken Resolve(JObject args)
        {
            var path = (string)args["path"]
                       ?? throw new BridgeException(ErrorCodes.BadRequest, "'path' is required");
            var go = Require(path);

            var result = new JObject
            {
                ["path"] = GetPath(go.transform),
                ["active"] = go.activeInHierarchy
            };

            Rect? screenRect = null;
            var isNgui = false;
            if (go.transform is RectTransform rt)
            {
                screenRect = ScreenRect(rt);
            }
            else if (NguiAdapter.TryGetScreenRect(go, out var nguiRect))
            {
                screenRect = nguiRect;
                isNgui = true;
                result["ui"] = "ngui";
            }

            if (screenRect is Rect rect)
            {
                result["rect"] = new JObject { ["x"] = rect.x, ["y"] = rect.y, ["w"] = rect.width, ["h"] = rect.height };
                result["center"] = new JObject { ["x"] = rect.center.x, ["y"] = rect.center.y };

                if (go.activeInHierarchy)
                {
                    var (hittable, blockedBy) = isNgui
                        ? NguiAdapter.Probe(go, rect.center)
                        : RaycastProbe.Probe(go, rect.center);
                    result["hittable"] = hittable;
                    if (blockedBy != null)
                        result["blockedBy"] = blockedBy;
                }
                else
                {
                    result["hittable"] = false;
                    result["blockedBy"] = "INACTIVE";
                }

                var nguiInteractable = isNgui ? NguiAdapter.Interactable(go) : null;
                if (nguiInteractable != null)
                    result["interactable"] = nguiInteractable.Value;
            }
            else
            {
                // 非UIオブジェクト: メインカメラ基準のスクリーン座標のみ返す
                var cam = Camera.main;
                if (cam != null)
                {
                    var sp = cam.WorldToScreenPoint(go.transform.position);
                    result["center"] = new JObject { ["x"] = sp.x, ["y"] = sp.y };
                }
            }

            var text = ExtractText(go);
            if (text != null)
                result["text"] = text;

            return result;
        }

        // ----------------------------------------------------------------- get

        public static JToken GetProperty(JObject args)
        {
            var path = (string)args["path"]
                       ?? throw new BridgeException(ErrorCodes.BadRequest, "'path' is required");
            var componentName = (string)args["component"]
                                ?? throw new BridgeException(ErrorCodes.BadRequest, "'component' is required");
            var propertyName = (string)args["property"]
                               ?? throw new BridgeException(ErrorCodes.BadRequest, "'property' is required");

            var go = Require(path);
            var component = go.GetComponents<Component>()
                .FirstOrDefault(c => c != null && c.GetType().Name == componentName);
            if (component == null)
                throw new BridgeException(ErrorCodes.NotFound,
                    $"component '{componentName}' not found on '{path}'. available: " +
                    string.Join(", ", go.GetComponents<Component>().Where(c => c != null).Select(c => c.GetType().Name)));

            var type = component.GetType();
            object value;
            var prop = type.GetProperty(propertyName, BindingFlags.Instance | BindingFlags.Public);
            if (prop != null)
            {
                value = prop.GetValue(component);
            }
            else
            {
                var field = type.GetField(propertyName, BindingFlags.Instance | BindingFlags.Public);
                if (field == null)
                    throw new BridgeException(ErrorCodes.NotFound,
                        $"public property/field '{propertyName}' not found on {componentName}");
                value = field.GetValue(component);
            }

            return new JObject { ["value"] = Serialize(value) };
        }

        private static JToken Serialize(object value)
        {
            switch (value)
            {
                case null: return JValue.CreateNull();
                case bool b: return b;
                case int i: return i;
                case long l: return l;
                case float f: return f;
                case double d: return d;
                case string s: return s;
                case Enum e: return e.ToString();
                case Vector2 v: return new JObject { ["x"] = v.x, ["y"] = v.y };
                case Vector3 v: return new JObject { ["x"] = v.x, ["y"] = v.y, ["z"] = v.z };
                case Color c: return new JObject { ["r"] = c.r, ["g"] = c.g, ["b"] = c.b, ["a"] = c.a };
                default: return value.ToString();
            }
        }

        // ------------------------------------------------------------- helpers

        /// <summary>
        /// パスでオブジェクトを解決する。
        /// "A/B/C" 形式はシーンルートからの絶対パス。'/' を含まない場合は名前で全検索し、
        /// 複数一致したら AMBIGUOUS エラーで候補パスを返す（AI が次の一手を選べるように）。
        /// </summary>
        public static GameObject Find(string path)
        {
            if (path.Contains("/"))
            {
                var segments = path.Split('/');
                // ルート候補は「全ルート Transform（parent==null）」から取る。
                // SceneManager.GetRootGameObjects だけだと DontDestroyOnLoad 配下の常駐UI
                // （実プロジェクトでは UI ルートを DDOL に載せるのが定石）に到達できず、
                // dump が返すパスで resolve すると NOT_FOUND になる。FindAll は DDOL も拾う。
                foreach (var root in FindAll<Transform>())
                {
                    if (root.parent != null || root.name != segments[0]) continue;
                    var current = root;
                    var ok = true;
                    for (var s = 1; s < segments.Length && ok; s++)
                    {
                        current = FindDirectChild(current, segments[s]);
                        ok = current != null;
                    }
                    if (ok) return current.gameObject;
                }
                return null;
            }

            var matches = FindAll<Transform>()
                .Where(t => t.name == path && t.gameObject.scene.isLoaded)
                .ToList();

            if (matches.Count == 0) return null;
            if (matches.Count > 1)
                throw new BridgeException(ErrorCodes.Ambiguous,
                    $"'{path}' matches {matches.Count} objects: " +
                    string.Join(", ", matches.Take(10).Select(GetPath)));
            return matches[0].gameObject;
        }

        public static GameObject Require(string path)
        {
            var go = Find(path);
            if (go == null)
                throw new BridgeException(ErrorCodes.NotFound, $"object not found: '{path}'");
            return go;
        }

        /// <summary>非アクティブ含む全シーンオブジェクト検索（Unityバージョン差の吸収）。</summary>
        private static T[] FindAll<T>() where T : UnityEngine.Object
        {
#if UNITY_2023_1_OR_NEWER
            return UnityEngine.Object.FindObjectsByType<T>(FindObjectsInactive.Include, FindObjectsSortMode.None);
#else
            return UnityEngine.Object.FindObjectsOfType<T>(true);
#endif
        }

        private static Transform FindDirectChild(Transform parent, string name)
        {
            for (var i = 0; i < parent.childCount; i++)
                if (parent.GetChild(i).name == name)
                    return parent.GetChild(i);
            return null;
        }

        public static string GetPath(Transform t)
        {
            var names = new List<string>();
            while (t != null)
            {
                names.Add(t.name);
                t = t.parent;
            }
            names.Reverse();
            return string.Join("/", names);
        }

        /// <summary>RectTransform のスクリーン座標矩形（Unity 座標系: 左下原点・ピクセル）。</summary>
        public static Rect ScreenRect(RectTransform rt)
        {
            var canvas = rt.GetComponentInParent<Canvas>();
            Camera cam = null;
            if (canvas != null && canvas.rootCanvas.renderMode != RenderMode.ScreenSpaceOverlay)
                cam = canvas.rootCanvas.worldCamera;

            var corners = new Vector3[4];
            rt.GetWorldCorners(corners);
            var min = new Vector2(float.MaxValue, float.MaxValue);
            var max = new Vector2(float.MinValue, float.MinValue);
            foreach (var corner in corners)
            {
                Vector2 sp = RectTransformUtility.WorldToScreenPoint(cam, corner);
                min = Vector2.Min(min, sp);
                max = Vector2.Max(max, sp);
            }
            return new Rect(min, max - min);
        }

        /// <summary>
        /// Text / TMP_Text / InputField 系から表示テキストを取り出す。
        /// TMP への直接依存を避けるためリフレクションで "text" プロパティを探す。
        /// </summary>
        private static string ExtractText(GameObject go)
        {
            foreach (var component in go.GetComponents<Component>())
            {
                if (component == null) continue;
                var typeName = component.GetType().Name;
                if (typeName != "Text" && typeName != "UILabel" &&
                    !typeName.Contains("TextMesh") && !typeName.Contains("TMP_") &&
                    !typeName.Contains("InputField") && !typeName.Contains("UIInput"))
                    continue;
                var prop = component.GetType().GetProperty("text", BindingFlags.Instance | BindingFlags.Public);
                if (prop?.PropertyType == typeof(string))
                    return (string)prop.GetValue(component);
            }
            return null;
        }
    }
}
