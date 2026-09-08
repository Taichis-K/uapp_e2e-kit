using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.EventSystems;

namespace E2EBridge
{
    /// <summary>
    /// uGUI（EventSystem）へ合成ポインタイベントを直接送出する。
    ///
    /// **入力バックエンドに依らない**のが唯一の存在理由。Active Input Handling が
    /// 「Input Manager (Old)」のプロジェクト（activeInputHandler: 0）や、
    /// com.unity.inputsystem を入れていないプロジェクトでは TouchInjector の注入が使えないので、
    /// uGUI を操作する手段がこれしかない。NGUI 側の <see cref="NguiAdapter"/> と同型で、
    /// ヒットテストは <see cref="RaycastProbe"/>（EventSystem.RaycastAll）を再利用する
    /// ＝ヒットテスト側は元からバックエンド非依存だったので、ここは送出だけを担う。
    ///
    /// <para><b>複数ポインタを同時に保持できる</b>（`pointerId` で区別する）。
    /// 「A を押しながら B をタップ」のような**マルチタッチのシナリオは uGUI の経路なら再現できる** ―
    /// ExecuteEvents は入力バックエンドと無関係だからで、レガシー Input の制約はここには効かない。
    /// 効かないのは次の場合だけ: <b>アプリが `Input.touchCount` / `Input.GetTouch` を直読みしている</b>
    /// （ピンチ実装によくある形）。レガシー Input には注入の API が存在しないので、
    /// そこへ届かせる手段は OS の実マルチタッチ以外に無い。</para>
    ///
    /// <para><b>限界（呼び手が知っておくこと）</b>: これは実入力ではない。
    /// 入力モジュールが組み立てる PointerEventData をこちらで作って ExecuteEvents へ流すので、
    /// **保証できるのは uGUI のイベント経路より内側**だけ。
    /// 「実際に指で触れて届くか」は adb の実タップで確かめること（`ngui_*` と同じ制約）。
    /// クリック成立とドラッグ開始の判定は `StandaloneInputModule` / `PointerInputModule` に
    /// **合わせてあるが、同一であることを実測で確かめてはいない**
    /// （合わせた先は com.unity.ugui 2.0.0 のソース。版が変われば挙動も変わりうる）。</para>
    /// </summary>
    public static class UguiAdapter
    {
        // 実タッチ（0 以上）・マウス（-1 / -2 / -3）と衝突しない領域へ写す。
        // 呼び手の pointerId 1 → -101、2 → -102 … と割り当てる。
        // **この写像は呼び手の id が 1 以上であることに依存する**（負値を許すと実タッチの id に化ける）
        private const int PointerIdBase = -100;
        private const int MinPointerId = 1;
        private const int MaxPointerId = 1000;

        private class Pointer
        {
            public PointerEventData Data;
            public GameObject Target;        // 押した対象（path が指したもの）
            public GameObject ClickHandler;  // 押した時点の IPointerClickHandler の受け手
            public bool Dragging;
        }

        private static readonly Dictionary<int, Pointer> _pointers = new Dictionary<int, Pointer>();
        private static readonly List<RaycastResult> _results = new List<RaycastResult>();

        /// <summary>押下中のポインタ数（`ping` の activePointers と input_reset が使う）。</summary>
        public static int ActiveCount => _pointers.Count;

        public static JToken HandleEvent(JObject args)
        {
            var eventSystem = RequireEventSystem();
            var eventName = (string)args["event"] ?? "click";
            var id = RequirePointerId(args);

            switch (eventName)
            {
                case "click":   return Click(eventSystem, args, id);
                case "press":   return Press(eventSystem, args, id);
                case "move":    return Move(eventSystem, args, id);
                case "release": return Release(eventSystem, args, id);
                default:
                    throw new BridgeException(ErrorCodes.BadRequest,
                        $"unknown event: '{eventName}' (click | press | move | release)");
            }
        }

        // ------------------------------------------------------------- イベント

        private static JToken Click(EventSystem eventSystem, JObject args, int id)
        {
            var down = (JObject)Press(eventSystem, args, id);
            var up = (JObject)Release(eventSystem, new JObject(), id);

            return new JObject
            {
                ["path"] = down["path"],
                ["event"] = "click",
                ["pointerId"] = id,
                ["handler"] = down["handler"],
                ["hittable"] = down["hittable"],
                ["blockedBy"] = down["blockedBy"],
                ["clicked"] = up["clicked"]
            };
        }

        private static JToken Press(EventSystem eventSystem, JObject args, int id)
        {
            if (_pointers.ContainsKey(id))
                throw new BridgeException(ErrorCodes.AlreadyPressed,
                    $"pointerId {id} は既に押下中です" +
                    "（別の指なら pointerId を変える / 離すなら ugui_event release か input_reset）");

            var path = (string)args["path"]
                       ?? throw new BridgeException(ErrorCodes.BadRequest, "'path' is required");
            var target = HierarchyDumper.Require(path);
            var position = ResolvePosition(target, args);

            // **応答に要るものは、台帳へ登録する前に取り切る**。
            // 登録の後で例外が出ると押下が残り、以後の press が全部 ALREADY_PRESSED になる
            //（`OnPointerDown` で自分を破棄する実装なら target.transform が MissingReference になる）。
            // Reset() の「1 本が落ちても残りは必ず解放する」思想をこちら側にも通す
            var targetPath = HierarchyDumper.GetPath(target.transform);

            // 実タップと同じ経路にするため、まず raycast して**当たった実体**へ送る。
            // 遮蔽されている場合は対象自身へ送るが、**その事実を隠さずに返す**
            //（黙って通すと「押せたのに何も起きない」を呼び手が追えなくなる）
            var (hittable, blockedBy, _) = RaycastProbe.Probe(target, position);
            var hit = Raycast(eventSystem, position, out var topResult);
            var dispatchFrom = (hittable && hit != null) ? hit : target;

            var data = new PointerEventData(eventSystem)
            {
                pointerId = PointerIdBase - id,
                button = PointerEventData.InputButton.Left,
                position = position,
                pressPosition = position,
                delta = Vector2.zero,
                clickCount = 1,
                clickTime = Time.unscaledTime,
                eligibleForClick = true,
                useDragThreshold = true,
                pointerCurrentRaycast = topResult,
                pointerPressRaycast = topResult
            };

            // hover を先に入れる（Button の遷移や、ホバーで開くメニューがあるため）
            data.pointerEnter = ExecuteEvents.ExecuteHierarchy(
                dispatchFrom, data, ExecuteEvents.pointerEnterHandler);

            // 入力モジュールと同じ順序: down を投げ、受け手が居なければ click の受け手へ倒す
            var clickHandler = ExecuteEvents.GetEventHandler<IPointerClickHandler>(dispatchFrom);
            var handler = ExecuteEvents.ExecuteHierarchy(
                dispatchFrom, data, ExecuteEvents.pointerDownHandler) ?? clickHandler;

            data.pointerPress = handler;
            data.rawPointerPress = dispatchFrom;

            // ScrollRect / Slider は「押した時点」でドラッグ候補にならないと後で動かない
            data.pointerDrag = ExecuteEvents.GetEventHandler<IDragHandler>(dispatchFrom);
            if (data.pointerDrag != null)
                ExecuteEvents.Execute(data.pointerDrag, data, ExecuteEvents.initializePotentialDrag);

            _pointers[id] = new Pointer
            {
                Data = data, Target = target, ClickHandler = clickHandler, Dragging = false
            };

            return new JObject
            {
                ["path"] = targetPath,
                ["event"] = "press",
                ["pointerId"] = id,
                ["handler"] = handler != null ? HierarchyDumper.GetPath(handler.transform) : null,
                ["hittable"] = hittable,
                ["blockedBy"] = blockedBy,
                ["x"] = position.x,
                ["y"] = position.y
            };
        }

        private static JToken Move(EventSystem eventSystem, JObject args, int id)
        {
            var p = RequirePointer(id);
            var position = ResolveMovePosition(args);
            var data = p.Data;

            data.delta = position - data.position;
            data.position = position;
            data.pointerCurrentRaycast = RaycastResultAt(eventSystem, position);

            // **ドラッグ開始の判定は入力モジュールに合わせる**（PointerInputModule.ShouldStartDrag）。
            // 「1px でも動いたら click 不成立」にすると、実入力ならクリックできる操作が
            // ここでだけ落ちる ― 検証と本番の食い違いになる
            if (data.pointerDrag != null && !p.Dragging && ShouldStartDrag(data, eventSystem))
            {
                p.Dragging = true;
                data.dragging = true;
                // click が消えるのは「押した相手とドラッグの相手が違う」ときだけ（入力モジュールと同じ）
                if (data.pointerPress != data.pointerDrag)
                    data.eligibleForClick = false;
                ExecuteEvents.Execute(data.pointerDrag, data, ExecuteEvents.beginDragHandler);
            }
            if (p.Dragging && data.pointerDrag != null)
                ExecuteEvents.Execute(data.pointerDrag, data, ExecuteEvents.dragHandler);

            return new JObject
            {
                ["event"] = "move",
                ["pointerId"] = id,
                ["dragging"] = p.Dragging,
                ["x"] = position.x,
                ["y"] = position.y
            };
        }

        private static JToken Release(EventSystem eventSystem, JObject args, int id)
        {
            var p = RequirePointer(id);

            // **何があっても台帳からは外す**。外れないと以後の press が全部 ALREADY_PRESSED になり、
            // 復旧路（input_reset）を呼ぶまで uGUI の操作ができなくなる。
            // 位置指定つき release は Move を通るので、そこで投げる可能性がある
            try
            {
                if (args["path"] != null || args["x"] != null)
                    Move(eventSystem, args, id);

                var data = p.Data;
                var pressedPath = p.Target != null ? HierarchyDumper.GetPath(p.Target.transform) : null;

                // **座標が変わらなくてもヒット対象は取り直す**。入力モジュールは毎フレーム
                // raycast し直すので、押下中に画面が変わった場合（別の指がローディング膜を
                // 出した等）は離した時点の対象で判定される。press 時の結果を使い回すと、
                // **遮蔽されたボタンにクリックが通る**（codex 指摘）
                data.pointerCurrentRaycast = RaycastResultAt(eventSystem, data.position);

                ExecuteEvents.Execute(data.pointerPress, data, ExecuteEvents.pointerUpHandler);

                // click は「離した位置の click 受け手が、**押した時点の click 受け手**と同じ」ときだけ成立する。
                // 入力モジュールは pointerPress（down の受け手）とは別に click の受け手を持つので、
                // **pointerPress と比べると、子に IPointerDownHandler がある階層で食い違う**
                var upTarget = data.pointerCurrentRaycast.gameObject;
                var upClickHandler = upTarget != null
                    ? ExecuteEvents.GetEventHandler<IPointerClickHandler>(upTarget)
                    : null;
                var clicked = data.eligibleForClick
                              && upClickHandler != null
                              && upClickHandler == p.ClickHandler;
                if (clicked)
                    ExecuteEvents.Execute(p.ClickHandler, data, ExecuteEvents.pointerClickHandler);

                // **drop を先に、endDrag を後に**（入力モジュールと同じ順序）。
                // 逆にすると、OnEndDrag で掴んでいるアイテム情報を捨てる実装で
                // OnDrop が受け取る時点に情報が無くなり、正しいアプリでも操作が成立しない
                if (p.Dragging && data.pointerDrag != null)
                {
                    if (upTarget != null)
                        ExecuteEvents.ExecuteHierarchy(upTarget, data, ExecuteEvents.dropHandler);
                    ExecuteEvents.Execute(data.pointerDrag, data, ExecuteEvents.endDragHandler);
                }

                if (data.pointerEnter != null)
                    ExecuteEvents.ExecuteHierarchy(data.pointerEnter, data, ExecuteEvents.pointerExitHandler);

                return new JObject
                {
                    ["path"] = pressedPath,
                    ["event"] = "release",
                    ["pointerId"] = id,
                    ["handler"] = data.pointerPress != null
                        ? HierarchyDumper.GetPath(data.pointerPress.transform) : null,
                    ["clicked"] = clicked
                };
            }
            finally
            {
                _pointers.Remove(id);
            }
        }

        /// <summary>押下したままのポインタを全部解放する（input_reset から呼ばれる）。</summary>
        public static int Reset()
        {
            if (_pointers.Count == 0) return 0;

            var released = _pointers.Count;
            // **1 本が例外で落ちても残りは必ず解放する**。掴んだままだと以後の press が
            // ALREADY_PRESSED で落ち続け、復旧路の失敗が直そうとしている状態を固定する
            foreach (var p in new List<Pointer>(_pointers.Values))
            {
                try
                {
                    if (p.Data.pointerPress != null)
                        ExecuteEvents.Execute(p.Data.pointerPress, p.Data, ExecuteEvents.pointerUpHandler);
                    if (p.Dragging && p.Data.pointerDrag != null)
                        ExecuteEvents.Execute(p.Data.pointerDrag, p.Data, ExecuteEvents.endDragHandler);
                    if (p.Data.pointerEnter != null)
                        ExecuteEvents.ExecuteHierarchy(p.Data.pointerEnter, p.Data, ExecuteEvents.pointerExitHandler);
                }
                catch (System.Exception ex)
                {
                    Debug.LogWarning($"[E2EBridge] uGUI ポインタの解放で例外: {ex.Message}");
                }
            }

            _pointers.Clear();
            return released;
        }

        // ------------------------------------------------------------- 補助

        /// <summary>入力モジュールと同じドラッグ開始判定（PointerInputModule.ShouldStartDrag 相当）。</summary>
        private static bool ShouldStartDrag(PointerEventData data, EventSystem eventSystem)
        {
            if (!data.useDragThreshold) return true;
            var threshold = eventSystem.pixelDragThreshold;
            return (data.pressPosition - data.position).sqrMagnitude >= (float)threshold * threshold;
        }

        private static Pointer RequirePointer(int id)
        {
            if (!_pointers.TryGetValue(id, out var p))
                throw new BridgeException(ErrorCodes.NotPressed,
                    $"pointerId {id} は押下されていません（先に ugui_event press を送ってください）");
            return p;
        }

        /// <summary>
        /// pointerId の検証。**素のキャストにしない** ― `1.9` が 2 に丸まり、`"abc"` は
        /// BridgeException ではない例外になって `INTERNAL` ＋スタックトレースで返る
        /// （呼び手のタイプミスが「計装の内部エラー」に見える）。TouchInjector.RequireInt と同じ趣旨。
        /// **負値を弾くのは必須**: `PointerIdBase - id` の写像が実タッチ・マウスの id に化ける
        /// （例 -99 → -1 ＝ マウス左）。
        /// </summary>
        private static int RequirePointerId(JObject args)
        {
            var token = args["pointerId"];
            if (token == null) return 1;
            if (token.Type != JTokenType.Integer)
                throw new BridgeException(ErrorCodes.BadRequest,
                    $"'pointerId' は整数で指定してください（受け取った型: {token.Type}）");
            var id = (int)token;
            if (id < MinPointerId || id > MaxPointerId)
                throw new BridgeException(ErrorCodes.BadRequest,
                    $"'pointerId' は {MinPointerId}〜{MaxPointerId} の範囲で指定してください（受け取った値: {id}）。" +
                    "この範囲外だと、実タッチやマウスと同じポインタ ID に化けます");
            return id;
        }

        private static EventSystem RequireEventSystem()
        {
            var eventSystem = EventSystem.current;
            if (eventSystem == null)
                throw new BridgeException(ErrorCodes.NoEventSystem,
                    "EventSystem がシーンにありません（uGUI を使っていないか、シーンの読み込みが終わっていない）");
            return eventSystem;
        }

        /// <summary>press の座標。x/y の明示があればそれ、無ければ対象のスクリーン矩形の中心。</summary>
        private static Vector2 ResolvePosition(GameObject target, JObject args)
        {
            if (args["x"] != null && args["y"] != null)
                return new Vector2((float)args["x"], (float)args["y"]);

            var rt = target.transform as RectTransform;
            if (rt == null)
                throw new BridgeException(ErrorCodes.BadRequest,
                    $"'{HierarchyDumper.GetPath(target.transform)}' は RectTransform を持たないので座標を決められません" +
                    "（uGUI の要素ではありません。x / y を明示するか、対象を見直してください）");

            return HierarchyDumper.ScreenRect(rt).center;
        }

        /// <summary>move / release の座標。path か x/y のどちらでも指定できる。</summary>
        private static Vector2 ResolveMovePosition(JObject args)
        {
            if (args["x"] != null && args["y"] != null)
                return new Vector2((float)args["x"], (float)args["y"]);

            var path = (string)args["path"];
            if (path == null)
                throw new BridgeException(ErrorCodes.BadRequest, "'path' または 'x'/'y' が要ります");

            return ResolvePosition(HierarchyDumper.Require(path), args);
        }

        private static GameObject Raycast(EventSystem eventSystem, Vector2 position, out RaycastResult top)
        {
            var probe = new PointerEventData(eventSystem) { position = position };
            _results.Clear();
            eventSystem.RaycastAll(probe, _results);
            top = _results.Count > 0 ? _results[0] : default;
            return _results.Count > 0 ? _results[0].gameObject : null;
        }

        private static RaycastResult RaycastResultAt(EventSystem eventSystem, Vector2 position)
        {
            Raycast(eventSystem, position, out var top);
            return top;
        }
    }
}
