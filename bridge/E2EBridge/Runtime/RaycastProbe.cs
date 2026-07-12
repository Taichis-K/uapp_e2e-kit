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
    }
}
