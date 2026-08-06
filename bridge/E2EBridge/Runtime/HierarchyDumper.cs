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
            else // "scene" / "all"
            {
                // **DontDestroyOnLoad 配下も列挙する**。SceneManager の列挙には出ないため、
                // 以前は resolve では届くのに dump には出ないという食い違いがあった。
                // 規約は「dump を見てから書く」なので、常駐オブジェクト（実プロジェクトの定石）が
                // dump の空白地帯になっていると、AI はコードを読むまで存在に気づけない。
                // Roots() は resolve と同じ並び（＝パス表記も一致する）
                roots.AddRange(Roots());
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
            // 常駐オブジェクト（シーン切替で消えない）であることを示す。
            // 「このシーンだけの UI か、常駐 UI か」でテストの書き方が変わる
            if (IsDontDestroyOnLoad(go))
                node["dontDestroyOnLoad"] = true;

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
                var (hittable, blockedBy, blocker) = isNgui
                    ? NguiAdapter.Probe(go, pr.center)
                    : RaycastProbe.Probe(go, pr.center);
                node["hittable"] = hittable;
                if (blockedBy != null)
                    node["blockedBy"] = blockedBy;
                if (blocker != null)
                    node["blockedByComponents"] = ComponentNames(blocker);
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

        /// <summary>
        /// 遮蔽オブジェクトが持つコンポーネント型名の一覧（Transform を除く・重複なし）。
        /// 呼び手が「押して退けるものか・待つべきものか」を機械判定するための事実情報。
        /// </summary>
        private static JArray ComponentNames(GameObject go)
        {
            var names = new JArray();
            var seen = new HashSet<string>();
            foreach (var component in go.GetComponents<Component>())
            {
                if (component == null || component is Transform) continue;   // Missing Script は null になる
                var name = component.GetType().Name;
                if (seen.Add(name)) names.Add(name);
            }
            return names;
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
                    var (hittable, blockedBy, blocker) = isNgui
                        ? NguiAdapter.Probe(go, rect.center)
                        : RaycastProbe.Probe(go, rect.center);
                    result["hittable"] = hittable;
                    if (blockedBy != null)
                        result["blockedBy"] = blockedBy;
                    // **「押して退けるものか・待つべきものか」を呼び手が機械判定するための材料**。
                    // 種別の解釈（shield か UI か）はプロジェクト固有なので、ブリッジは
                    // 事実（遮蔽者が持つコンポーネント型名）だけを返し、判断は呼び手に委ねる
                    if (blocker != null)
                        result["blockedByComponents"] = ComponentNames(blocker);
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
                    // コンポーネント名を間違えたときは候補を出しているのに、プロパティ名の
                    // 間違いでは出していなかった（名前を1文字違えるたびに手探りになる）
                    throw new BridgeException(ErrorCodes.NotFound,
                        $"public property/field '{propertyName}' not found on {componentName}. available: " +
                        string.Join(", ", AvailableMembers(type)));
                value = field.GetValue(component);
            }

            return new JObject { ["value"] = Serialize(value) };
        }

        /// <summary>読み取れる public のプロパティ／フィールド名（NOT_FOUND の候補表示用）。</summary>
        private static IEnumerable<string> AvailableMembers(Type type)
        {
            // 読めないもの（インデクサ・書き込み専用）は候補に出さない。多すぎても選べないので
            // 名前順に上限を設ける
            var names = type.GetProperties(BindingFlags.Instance | BindingFlags.Public)
                .Where(p => p.CanRead && p.GetIndexParameters().Length == 0)
                .Select(p => p.Name)
                .Concat(type.GetFields(BindingFlags.Instance | BindingFlags.Public).Select(f => f.Name));
            return names.Distinct().OrderBy(n => n, StringComparer.Ordinal).Take(40);
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
                // 子と同じく**実名を優先**して候補を並べる（`Item[0]` という名前のルートが実在しうる）
                ParseSegment(segments[0], out var rootName, out var rootIndex);
                var candidates = new List<Transform>();
                foreach (var root in Roots())
                    if (root.name == segments[0]) candidates.Add(root);
                if (rootIndex >= 0)
                {
                    var seenRoots = 0;
                    foreach (var root in Roots())
                    {
                        if (root.name != rootName) continue;
                        if (seenRoots++ != rootIndex) continue;
                        candidates.Add(root);
                        break;
                    }
                }
                foreach (var root in candidates)
                {
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

            // 名前だけの検索でも添字を受け付ける（dump が返した "Canvas[1]" をそのまま渡せる）。
            // ここでも**実名一致を先に見る**（`Item[0]` という名前のオブジェクトを取りこぼさない）
            var literal = FindAll<Transform>()
                .Where(t => t.name == path && t.gameObject.scene.isLoaded)
                .ToList();
            if (literal.Count == 1) return literal[0].gameObject;

            ParseSegment(path, out var wanted, out var wantedIndex);
            var matches = literal.Count > 1
                ? literal
                : FindAll<Transform>().Where(t => t.name == wanted && t.gameObject.scene.isLoaded).ToList();

            if (matches.Count == 0) return null;
            if (wantedIndex >= 0 && literal.Count == 0)
            {
                // 添字の意味は「同名の兄弟の中で何番目か」。dump が出す表記と必ず一致させるため、
                // 検索順ではなく **GetPath の末尾セグメントが一致するもの** を選ぶ
                var target = matches.FirstOrDefault(t => SegmentOf(t) == path);
                return target != null ? target.gameObject : null;
            }
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

        // 同名の兄弟を区別する添字（例: "Canvas[1]"）。**同名が複数あるときだけ**付けるので、
        // 一意な名前のパスは従来どおり（既存のテストが壊れない）
        private static readonly System.Text.RegularExpressions.Regex IndexSuffix =
            new System.Text.RegularExpressions.Regex(@"^(?<name>.*)\[(?<index>\d+)\]$");

        private static void ParseSegment(string segment, out string name, out int index)
        {
            var match = IndexSuffix.Match(segment);
            if (!match.Success) { name = segment; index = -1; return; }
            name = match.Groups["name"].Value;
            index = int.Parse(match.Groups["index"].Value);
        }

        private static Transform FindDirectChild(Transform parent, string segment)
        {
            // **実名を先に見る**。`Item[0]` のように名前自体が添字表記のオブジェクトは実在するので、
            // 先に添字として解釈すると dump が返したパスで解決できなくなる
            for (var i = 0; i < parent.childCount; i++)
                if (parent.GetChild(i).name == segment)
                    return parent.GetChild(i);

            ParseSegment(segment, out var name, out var index);
            if (index < 0) return null;
            var seen = 0;
            for (var i = 0; i < parent.childCount; i++)
            {
                var child = parent.GetChild(i);
                if (child.name != name) continue;
                if (seen == index) return child;
                seen++;
            }
            return null;
        }

        // ルートの並びは GetPath と Find で必ず一致させる（片方だけ順序が違うと、
        // dump が返したパスで resolve できなくなる）。1 フレーム内はキャッシュする
        private static Transform[] _roots = System.Array.Empty<Transform>();
        private static int _rootsFrame = -1;
        private static int _rootsCount = -1;
        private static Scene _ddolScene;      // DontDestroyOnLoad のシーン（件数の安い数え直し用）

        /// <summary>キャッシュしてよいか。**破棄済みを掴んだままにしない**ことが最優先。</summary>
        private static bool RootsCacheUsable()
        {
            // フレームが進んでいない＝同じ 1 コマンドの処理中、が基本の条件。ただし EditMode の
            // テスト実行のようにフレームが進まない文脈があるため、ルート数の変化と
            // 破棄済み参照の有無も見る（キャッシュを信じて破棄済みに触ると例外で全滅する）
            if (_rootsFrame != Time.frameCount || _rootsCount != SceneRootCount()) return false;
            foreach (var root in _roots)
                if (root == null) return false;
            return true;
        }

        /// <summary>DontDestroyOnLoad 配下か（Unity は専用シーンへ移す）。</summary>
        private static bool IsDontDestroyOnLoad(GameObject go)
        {
            var scene = go.scene;
            return scene.IsValid() && scene.buildIndex == -1 && scene.name == "DontDestroyOnLoad";
        }

        private static int SceneRootCount()
        {
            var total = 0;
            for (var i = 0; i < SceneManager.sceneCount; i++)
            {
                var scene = SceneManager.GetSceneAt(i);
                if (scene.isLoaded) total += scene.rootCount;
            }
            // **DontDestroyOnLoad のルートも数える**（SceneManager は DDOL を列挙しない）。
            // 常駐UIを DDOL に置く実プロジェクトで、同じフレーム内に増えたルートが
            // キャッシュから漏れると、そのルート配下のパスが解決できなくなる。
            // 走査コストを避けるため、前回の構築時に掴んだ DDOL の Scene から件数だけ読む
            if (_ddolScene.IsValid()) total += _ddolScene.rootCount;
            return total;
        }

        private static Transform[] Roots()
        {
            if (RootsCacheUsable()) return _roots;

            // 並べ替えキーで比較させない（Scene や GameObject は IComparable ではなく、
            // OrderBy に渡すと実行時に「At least one object must implement IComparable」で落ちる）。
            // シーンのルート配列の順にそのまま積み、そこに出てこないもの（DontDestroyOnLoad 配下）を
            // 後ろに足す。順序が実行ごとに変わらなければ添字の意味が保てる
            var ordered = new List<Transform>();
            var seen = new HashSet<int>();
            for (var i = 0; i < SceneManager.sceneCount; i++)
            {
                var scene = SceneManager.GetSceneAt(i);
                if (!scene.isLoaded) continue;
                foreach (var go in scene.GetRootGameObjects())
                {
                    ordered.Add(go.transform);
                    seen.Add(go.GetInstanceID());
                }
            }
            var extra = new List<Transform>();
            foreach (var t in FindAll<Transform>())
                if (t.parent == null && !seen.Contains(t.gameObject.GetInstanceID()))
                {
                    extra.Add(t);
                    // 件数だけ安く数え直せるよう DDOL の Scene を覚えておく（SceneManager は列挙しない）
                    if (!_ddolScene.IsValid()) _ddolScene = t.gameObject.scene;
                }
            extra.Sort((a, b) => a.GetInstanceID().CompareTo(b.GetInstanceID()));   // 実行間で安定させる
            ordered.AddRange(extra);

            _roots = ordered.ToArray();
            _rootsFrame = Time.frameCount;
            _rootsCount = SceneRootCount();
            return _roots;
        }

        /// <summary>同名の兄弟が居るときだけ添字を付けた 1 セグメント分の名前。</summary>
        private static string SegmentOf(Transform t)
        {
            if (t.parent == null)
            {
                var roots = Roots();
                var same = roots.Where(r => r.name == t.name).ToList();
                if (same.Count <= 1) return t.name;
                return $"{t.name}[{same.IndexOf(t)}]";
            }
            var parent = t.parent;
            var index = -1;
            var count = 0;
            for (var i = 0; i < parent.childCount; i++)
            {
                var child = parent.GetChild(i);
                if (child.name != t.name) continue;
                if (child == t) index = count;
                count++;
            }
            return count <= 1 ? t.name : $"{t.name}[{index}]";
        }

        public static string GetPath(Transform t)
        {
            var names = new List<string>();
            while (t != null)
            {
                names.Add(SegmentOf(t));
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
