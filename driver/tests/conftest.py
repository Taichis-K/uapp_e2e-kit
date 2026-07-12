# uapp_e2e キットの pytest フィクスチャ/フック（client / g / journey）を取り込む。
# 実体は e2e_driver パッケージ側にあり、キット更新は e2e_driver/ の差し替えだけで完結する。
# このファイルは初回導入時に生成された後は上書きされない —
# プロジェクト固有のフィクスチャやフックは、この下に自由に追加してよい。
from e2e_driver.pytest_journey import *  # noqa: F401,F403
