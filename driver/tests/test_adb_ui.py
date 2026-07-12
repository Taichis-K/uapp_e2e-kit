# adb の要素ベース・ネイティブUI操作（uiautomator XMLパーサ）の単体テスト。デバイス不要。
from e2e_driver.adb import find_ui_node

# uiautomator dump の抜粋を模した最小XML（アプリ選択ダイアログ相当）
XML = (
    '<?xml version="1.0"?><hierarchy rotation="1">'
    '<node text="アプリで開く" class="android.widget.TextView" resource-id="" bounds="[100,200][400,260]"/>'
    '<node text="DEV1_D" class="android.widget.TextView" resource-id="" bounds="[1000,500][1300,560]"/>'
    '<node text="1 回のみ" class="android.widget.Button" resource-id="android:id/button_once" bounds="[200,900][600,1000]"/>'
    '<node text="" class="android.widget.EditText" resource-id="acct" bounds="[50,400][900,480]"/>'
    '</hierarchy>')


def test_find_by_text_exact_and_contains():
    assert find_ui_node(text="DEV1_D", xml=XML)["center"] == (1150, 530)
    assert find_ui_node(text="DEV1", xml=XML) is None, "完全一致では部分文字列にヒットしない"
    assert find_ui_node(text="DEV1", contains=True, xml=XML)["center"] == (1150, 530)
    # 全角/半角ゆらぎのある「1 回のみ」を部分一致で拾える
    assert find_ui_node(text="回のみ", contains=True, xml=XML)["resource-id"] == "android:id/button_once"


def test_find_by_class_and_resource_id():
    edit = find_ui_node(class_name="android.widget.EditText", xml=XML)
    assert edit["center"] == (475, 440) and edit["resource-id"] == "acct"
    assert find_ui_node(resource_id="acct", xml=XML)["class"] == "android.widget.EditText"


def test_find_returns_none_when_absent():
    assert find_ui_node(text="存在しない", xml=XML) is None
    assert find_ui_node(class_name="android.webkit.WebView", xml=XML) is None
