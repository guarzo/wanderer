# ZKB Module Refactoring Tasks

## 1. HTTP Client Refactoring
- [x] Create new module `WandererApp.Zkb.HttpClient`
- [x] Implement `fetch_kills/1` function:
  - [x] Define spec: `@spec fetch_kills(system_id :: integer()) :: {:ok, any()} | {:error, term()}`
  - [x] Construct bucket name as `"zkb_#{system_id}"`
  - [x] Call `HttpUtil.get_with_rate_limit/2` with:
    - [x] `bucket: bucket`
    - [x] `limit: 10`
    - [x] `scale_ms: 1_000`
  - [x] Build full ZKB URL using `zkb_url/1`
  - [x] Return parsed JSON or error
- [x] Extract rate-limit checks into the new module
- [x] Extract `Req.get!` calls into the new module
- [x] Extract status-code handling into the new module
- [x] Extract retry/backoff logic into the new module
- [x] Implement `get_json/1` function with automatic backoff
- [x] Add proper error handling and logging
- [x] Ensure defaults and error handling are encapsulated
- [x] Update all ZKB code to use `HttpClient.fetch_kills/1`:
  - [x] Update `RedisQ` module to use `HttpClient.poll_redisq/1`
  - [x] Update `ZkbApi` module to use `HttpClient.fetch_kills_page/2`
  - [x] Update `Fetcher` module to use `HttpClient` for HTTP operations

## 2. Cache Key Management
- [ ] Create new module `WandererApp.Zkb.Key`
- [ ] Move all cache-key functions to the new module:
  - [ ] `killmail_key/1`
  - [ ] `system_kills_key/1`
  - [ ] `fetched_timestamp_key/1`
- [ ] Move `current_time_ms/0` to the new module
- [ ] Update all references in `KillsCache` and related modules
- [ ] Add documentation for all key functions

## 3. Parser Pipeline Improvements
- [ ] Break down `parse_full_and_store/3` into smaller functions
- [ ] Implement multiple `parse_time/1` clauses for ISO-8601 parsing
- [ ] Create clear pipeline structure:
  ```elixir
  build_kill_data(km)
  |> maybe_enrich()
  |> put_into_cache()
  |> inc_counter_if_recent()
  ```
- [ ] Delegate retry loops to `HttpClient.request_with_retry/1`

## 4. Preloader Parameterization
- [ ] Consolidate 'quick' and 'expanded' preloading into `handle_pass/3`
- [ ] Define pass configuration as module attribute:
  ```elixir
  @passes %{
    quick: %{limit: 50, hours: 1},
    expanded: %{limit: 500, hours: 24}
  }
  ```
- [ ] Refactor to use single `Task.async_stream` block
- [ ] Implement unified result-reducer

## 5. Supervisor Improvements
- [ ] Update all GenServers in `lib/wanderer_app/zkb` to:
  - [ ] Implement `@behaviour Supervisor.Spec`
  - [ ] Add `@impl true` to `child_spec/1`
- [ ] Simplify `Zkb.Supervisor` to list modules directly
- [ ] Switch runtime-spawned workers to `DynamicSupervisor`

## 6. Type Specifications
- [ ] Add `@spec` annotations to all public functions in:
  - [ ] `Fetcher` module
  - [ ] `Parser` module
  - [ ] `Cache` module
- [ ] Ensure accurate input/output type descriptions
- [ ] Verify Dialyzer compatibility

## 8. Code Style Improvements
- [ ] Review and rename ambiguous variables:
  - [ ] Replace `st1` with `prev_state`
  - [ ] Replace `acc_st` with `new_state`
- [ ] Convert nested `Map.put` calls to pipelines
- [ ] Standardize module aliases
- [ ] Clean up function naming
