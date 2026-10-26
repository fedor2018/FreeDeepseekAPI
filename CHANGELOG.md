# Changelog

## Latest Changes

### Added

• deleteRemoteChat: remove the remote DeepSeek chat via `POST /api/v0/chat_session/delete` (fire-and-forget).
• `/delete-session`: now also deletes the upstream chat when a sticky account exists (`remote_deleted: 'pending'`).
• tests/deleteRemoteChat.test.mjs: unit tests for the delete-session contract.

### Changed

• README.md and docs/api-documentation.md: remote chat delete is no longer described as unavailable.
• scripts/doctor.js: hints for `delete-session?agent=<id>` and `delete-session?agent=all`.

--------

Update assisted by OpenCode
