# uapp_e2e — E2Eテストキット

このディレクトリで作業する前に [CLAUDE.md](CLAUDE.md)（エージェント共通の運用ガイド:
規約・コマンド・失敗解析手順。ファイル名は歴史的経緯で、内容は Claude 専用ではない）を読むこと。

- セットアップ・修復: [SETUP.md](SETUP.md)（AI向けランブック）
- テスト作成・失敗解析の詳細: [docs/ai-loop.md](docs/ai-loop.md)

定型作業（セットアップ/実行/テスト作成/UI dump）はプロジェクトルートの
`.agents/skills/e2e-*`（Codex は `$e2e-run` 等で呼び出し、または `/skills` から選択）にもある。
