# Changelog

## Latest Changes

### Fixed

• planSessionTurn: alignment walk вместо позиційного порівняння — echoed/rewritten
  assistant-повороти (tools flow) і обрізана клієнтом історія більше не перезапускають
  remote-чат DeepSeek (баг «нові ds-sessions за однієї OpenCode-сесії», історія 20 chat).
• stableSystemFingerprint: contextKey тепер хешує system prompt без дат/часів/UUID —
  волатильні вставки агентів не класифікуються як «system prompt changed».
• Нова сесійна ознака contextRawKey: delta-поворот включає system під час raw-зміни
  (includeSystem), навіть коли стабільний fingerprint не змінився.

### Added

• retireRemoteChatById: перед кожним reset/rollover/rotation/`/new`/idle sweep
  попередній remote-чат видаляється через `POST /api/v0/chat_session/delete` —
  orphan-чати більше не накопичуються у DeepSeek-акаунті.
• Вимикач `DEEPSEEK_DISABLE_ORPHAN_CLEANUP=1` (offline-тести).
• Тести: продолжение чата при trimmed history та echoed assistant, стабільний
  fingerprint на волатильних system prompts.

### Changed

• deleteRemoteChat тепер враховує статус відповіді: 200/404 = видалено, інакше false.
• `/delete-session`: await результату видалення; `remote_deleted: 'deleted' | 'failed' | 'skipped'`.
• `/delete-session?agent=all`, `/new` та idle sweep теж ретайрять remote-чати.
• README.md: опис orphan-очищення й нового контракту `remote_deleted`.

### Added (earlier)

• deleteRemoteChat: remove the remote DeepSeek chat via `POST /api/v0/chat_session/delete` (fire-and-forget).
• `/delete-session`: now also deletes the upstream chat when a sticky account exists.
• tests/deleteRemoteChat.test.mjs: unit tests for the delete-session contract.

### Changed (earlier)

• README.md and docs/api-documentation.md: remote chat delete is no longer described as unavailable.
• scripts/doctor.js: hints for `delete-session?agent=<id>` and `delete-session?agent=all`.

--------

Update assisted by OpenCode
