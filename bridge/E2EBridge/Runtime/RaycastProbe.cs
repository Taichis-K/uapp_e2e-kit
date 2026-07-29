using System.Collections.Generic;
using UnityEngine;
using UnityEngine.EventSystems;

namespace E2EBridge
{
    /// <summary>
    /// 「その座標を実ユーザーがタッチしたとき、本当にこのオブジェクトに届くか」を判定する。
    /// EventSystem.RaycastAll で最前面のヒットを取り、対象自身またはその子孫なら hittable。
    /// 全画面ブロッカー等に遮られている場合は blockedBy に遮蔽オブジェクトのパスを返す。
    /// </summary>
    public static class RaycastProbe
    {
        private static readonly List<RaycastResult> _results = new List<RaycastResult>();

        public static (bool hittable, string blockedBy) Probe(GameObject target, Vector2 screenPos)
        {
            var eventSystem = EventSystem.current;
            if (eventSystem == null)
                return (false, "NO_EVENTSYSTEM");

            // **対象がそもそも raycast の的でない**ことを最初に判定する。
            // これは対象自身の性質なので、その場に何が居るかより確実で、対処も違う:
            //   遮蔽 → 先に閉じる / wait_until_hittable で待てば解ける
            //   的でない → 待っても永久に押せない（指しているパスが間違っている）
            // 後回しにすると NOTHING_HIT や無関係な遮蔽者のパスに埋もれて、AI が誤った対象を追う
            if (!IsRaycastTarget(target))
                return (false, "NOT_RAYCASTABLE");

            var pointer = new PointerEventData(eventSystem) { position = screenPos };
            _results.Clear();
            eventSystem.RaycastAll(pointer, _results);

            if (_results.Count == 0)
                return (false, "NOTHING_HIT");

            // RaycastAll はソート済み。先頭が最前面
            var top = _results[0].gameObject;
            if (top.transform == target.transform || top.transform.IsChildOf(target.transform))
                return (true, null);

            return (false, HierarchyDumper.GetPath(top.transform));
        }

        /// <summary>対象自身か子孫に、raycast を受けられる要素が 1 つでもあるか。</summary>
        private static bool IsRaycastTarget(GameObject target)
        {
            // uGUI: Graphic の raycastTarget が実質の判定。Selectable だけでは受けられない
            foreach (var graphic in target.GetComponentsInChildren<UnityEngine.UI.Graphic>(true))
                if (graphic != null && graphic.raycastTarget) return true;
            // uGUI 以外（NGUI 等）の当たり判定はコライダー側にある
            foreach (var collider in target.GetComponentsInChildren<Collider>(true))
                if (collider != null && collider.enabled) return true;
            foreach (var collider2d in target.GetComponentsInChildren<Collider2D>(true))
                if (collider2d != null && collider2d.enabled) return true;
            return false;
        }
    }
}
