# PR Feedback

## Map Event Handler Inconsistency
- [ ] In `lib/wanderer_app_web/live/map/event_handlers/map_kills_event_handler.ex` (lines 29-39):
  - The error case in `handle_server_event` returns `{:noreply, socket}` while the success case returns just `socket`
  - Fix: Change the error case to return only `socket` instead of `{:noreply, socket}` to maintain consistency

## Redundant Code in Connections
- [ ] In `lib/wanderer_app/map/operations/connections.ex` (lines 47-62):
  - Remove redundant parsing of source and target solar system IDs
  - Eliminate unused parameters `src_info` and `tgt_info` from function signature
  - Extract source and target IDs directly from `src_info` and `tgt_info` within the function

## JSON Decode Error Handling
- [ ] In `lib/wanderer_app/utils/http_util.ex` (lines 68-79):
  - Current code assumes response body is always valid JSON
  - Fix: Add proper error handling for JSON decode failures
  - Implement pattern matching on error tuples from `Req.get`
  - Return appropriate error tuples or log decode failures

## Killmail Count Optimization
- [ ] In `lib/wanderer_app/map/map_zkb_data_fetcher.ex` (lines 86-88):
  - Replace current killmail fetching and counting with direct call to `Cache.get_kill_count/1`
  - Remove call to `Cache.get_killmails_for_system` and `length`
  - Assign `kills_count` using `Cache.get_kill_count(solar_system_id)`
  - Return `{solar_system_id, kills_count}`

## Error Detail Preservation
- [ ] In `lib/wanderer_app/zkb/provider/parser/enricher.ex` (lines 30-35):
  - Current rescue clause returns generic error tuple, losing original error details
  - Fix: Include caught exception information in returned error tuple
  - Preserve error details for better debugging
  - Maintain current error logging

## Cache Error Handling
- [ ] In `lib/wanderer_app/zkb/provider/fetcher.ex` (lines 83-84):
  - Add error handling for `Cache.get_killmails_for_system` results
  - Implement pattern matching on cache retrieval results
  - Return appropriate error tuples for cache failures
  - Ensure function doesn't signal success with incomplete/missing data

## Task Monitoring Implementation
- [ ] In `lib/wanderer_app/zkb/preloader.ex` (lines 82-84):
  - Replace `Task.start` with `Task.Supervisor.start_child`
  - Implement proper task monitoring
  - Add crash notification handling
  - Ensure GenServer can handle task failures

## Log Message Update
- [ ] In `lib/wanderer_app/zkb/preloader.ex` (line 156):
  - Update outdated module name "KillsPreloader" in error log message
  - Ensure logging reflects current module name

## Retry Logic Refactoring
- [ ] In `lib/wanderer_app/zkb/provider/parser.ex` (lines 35-47 and 144-164):
  - Refactor `retry_with_backoff/3` function
  - Replace existing error checks with calls to `is_retriable_error?` macro
  - Ensure consistent handling of retriable error conditions
  - Eliminate duplicated code