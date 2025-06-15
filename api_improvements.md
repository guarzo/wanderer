## 🔧 Test Infrastructure Priorities

### 25. ✅ Mock Map Server State Management
**Goal**: Enable integration tests that require map server state without running actual GenServer processes.

**Status**: **COMPLETED** - Infrastructure implemented and documented

**Problem**: 
- ~30 skipped tests require map server GenServer to be running
- Map state loading in test environment is complex and unreliable
- Tests fail because map cache and GenServer state isn't properly initialized

**Implementation Strategy**:
- Create `MapServerMock` module that simulates map server behavior
- Mock map cache initialization and state management
- Provide test helpers for setting up map state scenarios
- Enable tests to run without actual GenServer processes

**Key Areas**:
1. **Map Cache Mocking**: Mock `Cachex` operations for map state
2. **GenServer State Simulation**: Provide map server state without actual processes
3. **Test Helpers**: Easy setup for complex map scenarios (systems, connections, characters)
4. **Factory Integration**: Ensure factory-created maps work with mocked state

**Files to create/modify**:
- `test/support/map_server_mock.ex` - Main mock implementation
- `test/support/map_test_helpers.ex` - Test setup helpers
- `test/api/support/api_case.ex` - Integration with ApiCase
- Update functional test files to use mocked state

**Expected Impact**: Enable ~30 skipped integration tests

**Implementation Summary**:
- Created `MapServerMock` module for simulating map server state
- Added `MapTestHelpers` for convenient test setup
- Integrated with `ApiCase` for automatic mock setup
- Updated Factory to use mocks when available
- Created comprehensive documentation and examples
- Mock infrastructure is backward compatible with existing tests

---

### 26. Comprehensive API Authentication Fixtures
**Goal**: Create proper API key mocking and authentication fixtures for all test scenarios.

**Priority**: **HIGH** (blocks ~25 tests)

**Problem**:
- Tests require valid API keys but don't have reliable fixtures
- Authentication setup is inconsistent across test files
- Some tests use mock tokens that don't match production behavior

**Implementation Strategy**:
- Enhance existing factory to generate valid API keys
- Create authentication test helpers for all auth strategies
- Standardize auth setup across all API test files
- Add comprehensive auth failure scenarios

**Key Areas**:
1. **API Key Generation**: Realistic API key creation in factories
2. **Auth Strategy Testing**: Test all authentication methods (JWT, API keys, ACL keys)
3. **Permission Testing**: Test various permission levels and role hierarchies
4. **Error Scenarios**: Test authentication failures and edge cases

**Files to create/modify**:
- Enhanced `test/support/factory.ex` with proper API key generation
- Enhanced `test/support/auth_helpers.ex` with all auth strategies
- Update test files to use standardized auth setup
- Add comprehensive auth test scenarios

**Expected Impact**: Enable ~25 skipped authentication-related tests

---

### 27. Refactor Phoenix Router Pipelines to AuthPipeline
**Goal**: Refactor all Phoenix router pipelines to use WandererAppWeb.Auth.AuthPipeline with explicit strategies; then delete the legacy plugs CheckMapApiKey, CheckAclApiKey, and CheckAclAuth.

**Priority**: **HIGH**

**Problem**:
- Multiple legacy authentication plugs with overlapping functionality
- Inconsistent authentication patterns across routes
- Difficult to maintain multiple authentication strategies

**Implementation Strategy**:
- Migrate all pipelines to use AuthPipeline with explicit strategies
- Remove legacy plugs after successful migration
- Ensure all routes use consistent authentication

**Expected Impact**: Cleaner, more maintainable authentication system

---

### 28. Secure Token Comparison
**Goal**: Search the codebase for any manual token comparisons and replace them with Plug.Crypto.secure_compare/2; fail CI if any remain.

**Priority**: **HIGH** (security critical)

**Problem**:
- Manual string comparisons for tokens are vulnerable to timing attacks
- No CI enforcement of secure comparison practices

**Implementation Strategy**:
- Audit codebase for manual token comparisons
- Replace with Plug.Crypto.secure_compare/2
- Add CI check to prevent regression

**Expected Impact**: Enhanced security against timing attacks

---

### 29. Remove Unused AssignMapOwner Plug
**Goal**: Remove the unused AssignMapOwner plug after controllers load owner data via ResolveMapIdentifier; run integration tests to confirm behaviour is identical.

**Priority**: **MEDIUM**

**Problem**:
- Dead code from previous refactoring
- Potential confusion about which code path is active

**Implementation Strategy**:
- Verify controllers use ResolveMapIdentifier
- Remove AssignMapOwner plug
- Run full integration test suite

**Expected Impact**: Cleaner codebase, reduced maintenance burden

---

### 30. Deprecate CheckAclAuth
**Goal**: Annotate CheckAclAuth with @deprecated today and schedule its deletion once the AuthPipeline migration is merged.

**Priority**: **MEDIUM**

**Problem**:
- Legacy authentication plug being replaced by AuthPipeline
- Need clear deprecation timeline

**Implementation Strategy**:
- Add @deprecated annotation with removal date
- Document migration path to AuthPipeline
- Schedule removal after migration complete

**Expected Impact**: Clear migration path for legacy code

---

### 31. Deprecated Route Sunset Policy
**Goal**: Adopt a six-month sunset policy for /deprecated_api/** routes; write failing integration tests that remind us to return HTTP 410 after <date>.

**Priority**: **LOW**

**Problem**:
- Deprecated routes linger indefinitely
- No systematic removal process

**Implementation Strategy**:
- Implement sunset policy with clear timeline
- Add integration tests that fail after sunset date
- Return HTTP 410 Gone after sunset

**Expected Impact**: Systematic API deprecation process

---

### 32. Legacy Controller Deprecation
**Goal**: Add @deprecated "Use /api/v1 … JSON:API – removes after 2025-12-31" to every legacy controller that exists only for compatibility.

**Priority**: **MEDIUM**

**Problem**:
- Legacy controllers maintained for backwards compatibility
- No clear migration timeline for clients

**Implementation Strategy**:
- Add deprecation notices to legacy controllers
- Set removal date (2025-12-31)
- Document migration path to JSON:API

**Expected Impact**: Clear migration timeline for API clients

---

### 33. Enable FallbackController
**Goal**: Enable action_fallback WandererAppWeb.FallbackController in every API controller and delete manual put_status/2 + json/2 error branches.

**Priority**: **MEDIUM**

**Problem**:
- Inconsistent error handling across controllers
- Manual error response code duplication

**Implementation Strategy**:
- Add action_fallback to all API controllers
- Remove manual error handling branches
- Ensure consistent error response format

**Expected Impact**: Consistent error handling, less code duplication

---

### 34. Extract OpenAPI Schemas
**Goal**: Extract repeated OpenAPI structs into WandererAppWeb.Schemas and reference them; remove in-controller schema definitions.

**Priority**: **MEDIUM** (quick win)

**Problem**:
- OpenAPI schema definitions duplicated across controllers
- ~15% of controller LOC is schema definitions

**Implementation Strategy**:
- Create WandererAppWeb.Schemas module
- Extract common schemas
- Update controllers to reference shared schemas

**Expected Impact**: ~15% reduction in controller LOC

---

### 35. Standardize Input Validation
**Goal**: Replace ad-hoc with/1 parameter checks with Ecto.Changeset or Ash changesets so invalid input yields uniform 422 responses.

**Priority**: **MEDIUM**

**Problem**:
- Inconsistent parameter validation
- Various error response formats

**Implementation Strategy**:
- Replace with/1 checks with changesets
- Ensure all validation errors return 422
- Standardize error response format

**Expected Impact**: Consistent input validation and error responses

---

### 36. Simplify API Map Pipeline
**Goal**: Collapse the :api_map pipeline to ResolveMapIdentifier → AuthPipeline(:map_api_key) → subscription_guard and delete AssignMapOwner & CheckMapSubscription plugs.

**Priority**: **HIGH**

**Problem**:
- Complex pipeline with redundant plugs
- Difficult to understand authentication flow

**Implementation Strategy**:
- Simplify pipeline to three stages
- Remove redundant plugs
- Test thoroughly to ensure identical behavior

**Expected Impact**: Cleaner, more maintainable pipeline

---

### 37. Feature Flag Integration
**Goal**: Convert feature-flag plugs (CheckApiDisabled, CheckCharacterApiDisabled, CheckKillsDisabled) into AuthPipeline strategies using the built-in feature_flag: option.

**Priority**: **LOW**

**Problem**:
- Feature flags implemented as separate plugs
- Inconsistent with AuthPipeline approach

**Implementation Strategy**:
- Implement feature flags as AuthPipeline strategies
- Remove dedicated feature flag plugs
- Use built-in feature_flag option

**Expected Impact**: Unified authentication and feature flag system

---

### 38. Telemetry for Map/ACL Operations
**Goal**: Emit Telemetry events for map / ACL create-update-delete actions so dashboards replace verbose logs.

**Priority**: **LOW**

**Problem**:
- Verbose logging for debugging
- No structured observability

**Implementation Strategy**:
- Add Telemetry events for CRUD operations
- Create dashboard integration
- Reduce verbose logging

**Expected Impact**: Better observability, less log noise

---

### 39. Property-Based Testing for Ash Resources
**Goal**: Introduce property-based tests for Ash resources; remove redundant HTTP permutation tests once confidence is gained.

**Priority**: **LOW**

**Problem**:
- Many HTTP permutation tests
- Could be replaced with property-based testing

**Implementation Strategy**:
- Add property-based tests for Ash resources
- Gradually remove redundant HTTP tests
- Maintain test coverage

**Expected Impact**: More robust testing with less code

---

### 40. Deprecate Phoenix Controllers for AshJsonApi
**Goal**: For controllers already migrated to AshJsonApi, mark Phoenix versions @deprecated and plan their removal after clients cut over.

**Priority**: **MEDIUM**

**Problem**:
- Duplicate implementations (Phoenix + AshJsonApi)
- Need migration path for clients

**Implementation Strategy**:
- Mark Phoenix controllers @deprecated
- Set removal timeline after client migration
- Document migration path

**Expected Impact**: Single API implementation

---

### 41. Complete Partial Controller Migrations
**Goal**: For partially migrated controllers, move non-CRUD logic into WandererApp.Domain.* modules and expose CRUD via a single custom Ash action; then delete the old controller.

**Priority**: **MEDIUM**

**Problem**:
- Some controllers partially migrated to Ash
- Business logic mixed with HTTP concerns

**Implementation Strategy**:
- Extract non-CRUD logic to Domain modules
- Implement as Ash custom actions
- Delete legacy controllers

**Expected Impact**: Clean separation of concerns

---

### 42. Delete CheckAclApiKey (Quick Win)
**Goal**: Delete CheckAclApiKey immediately (zero references) and ensure the test suite passes.

**Priority**: **HIGH** (quick win)

**Problem**:
- Dead code with zero references
- Easy removal

**Implementation Strategy**:
- Delete CheckAclApiKey plug
- Run test suite to confirm
- Commit immediately

**Expected Impact**: Cleaner codebase

---

### 43. Centralize OpenAPI Schemas (Quick Win)
**Goal**: Centralise shared OpenAPI schemas today (≈ ½ day effort) to cut controller LOC by ~15%.

**Priority**: **HIGH** (quick win)

**Problem**:
- Duplicate OpenAPI schema definitions
- Quick improvement opportunity

**Implementation Strategy**:
- Create central schema module
- Extract shared schemas
- Update controllers

**Expected Impact**: ~15% LOC reduction

---

### 44. Complete AuthPipeline Migration (Quick Win)
**Goal**: Finish swapping every router pipeline to AuthPipeline (≈ 1 day) and commit.

**Priority**: **HIGH** (quick win)

**Problem**:
- Partially migrated authentication
- Can be completed quickly

**Implementation Strategy**:
- Complete pipeline migration
- Remove legacy plugs
- Test and commit

**Expected Impact**: Unified authentication system

---

### 45. Purge Legacy API Controllers
**Goal**: After client migration, purge all legacy /api/map/** controllers and plugs (≈ 2 days); tag the PR 'API-surface-reduction'.

**Priority**: **MEDIUM**

**Problem**:
- Legacy API surface maintained for compatibility
- Ready for removal after client migration

**Implementation Strategy**:
- Confirm client migration complete
- Remove all legacy /api/map/** code
- Tag PR for visibility

**Expected Impact**: Significant API surface reduction6