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

### 26. ✅ Comprehensive API Authentication Fixtures
**Goal**: Create proper API key mocking and authentication fixtures for all test scenarios.

**Status**: **COMPLETED** - Enhanced auth helpers with all authentication strategies

**Priority**: **HIGH** (blocks ~25 tests)

**Problem**:
- Tests require valid API keys but don't have reliable fixtures
- Authentication setup is inconsistent across test files
- Some tests use mock tokens that don't match production behavior

**Implementation Summary**:
- ✅ Enhanced `test/support/auth_helpers.ex` with API key generation helpers
- ✅ Added `generate_map_api_key_header` and `generate_acl_api_key_header` functions
- ✅ Created unified `setup_auth` function for all authentication strategies
- ✅ Enhanced factory with `create_map_with_api_key` and `create_access_list_with_api_key`
- ✅ Added `create_auth_test_setup` for complete test scenarios
- ✅ Created `test/support/auth_test_scenarios.ex` for comprehensive auth testing

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

### 27. 🔄 Refactor Phoenix Router Pipelines to AuthPipeline
**Goal**: Refactor all Phoenix router pipelines to use WandererAppWeb.Auth.AuthPipeline with explicit strategies; then delete the legacy plugs CheckMapApiKey, CheckAclApiKey, and CheckAclAuth.

**Status**: **INCOMPLETE** - AuthPipeline exists but router still uses legacy plugs

**Priority**: **HIGH**

**Problem**:
- Multiple legacy authentication plugs with overlapping functionality
- Inconsistent authentication patterns across routes
- Difficult to maintain multiple authentication strategies

**Current State**:
- ✅ AuthPipeline module implemented at `lib/wanderer_app_web/auth/auth_pipeline.ex`
- ❌ Router still uses legacy plugs (CheckMapApiKey, CheckAclAuth)
- ❌ Legacy plugs not yet removed

**Implementation Strategy**:
- Migrate all pipelines to use AuthPipeline with explicit strategies
- Remove legacy plugs after successful migration
- Ensure all routes use consistent authentication

**Expected Impact**: Cleaner, more maintainable authentication system

---

### 28. ✅ Secure Token Comparison
**Goal**: Search the codebase for any manual token comparisons and replace them with Plug.Crypto.secure_compare/2; fail CI if any remain.

**Status**: **COMPLETED** - All token comparisons now use secure_compare

**Priority**: **HIGH** (security critical)

**Problem**:
- Manual string comparisons for tokens are vulnerable to timing attacks
- No CI enforcement of secure comparison practices

**Implementation Summary**:
- ✅ Fixed insecure comparison in `check_acl_auth.ex` line 48
- ✅ Fixed insecure comparison in `license_auth.ex` line 28
- ✅ All authentication comparisons now use `Plug.Crypto.secure_compare`
- ⚠️ CI check not implemented (requires separate CI configuration)

**Implementation Strategy**:
- Fix the insecure comparison in check_acl_auth.ex
- Audit codebase for any other manual comparisons
- Add CI check to prevent regression

**Expected Impact**: Enhanced security against timing attacks

---

### 29. ❌ Remove Unused AssignMapOwner Plug
**Goal**: Remove the unused AssignMapOwner plug after controllers load owner data via ResolveMapIdentifier; run integration tests to confirm behaviour is identical.

**Status**: **INCOMPLETE** - Plug still exists

**Priority**: **MEDIUM**

**Problem**:
- Dead code from previous refactoring
- Potential confusion about which code path is active

**Current State**:
- ❌ AssignMapOwner plug still exists at `lib/wanderer_app_web/controllers/plugs/assign_map_owner.ex`

**Implementation Strategy**:
- Verify controllers use ResolveMapIdentifier
- Remove AssignMapOwner plug
- Run full integration test suite

**Expected Impact**: Cleaner codebase, reduced maintenance burden

---

### 30. ❌ Deprecate CheckAclAuth
**Goal**: Annotate CheckAclAuth with @deprecated today and schedule its deletion once the AuthPipeline migration is merged.

**Status**: **INCOMPLETE** - No deprecation annotation

**Priority**: **MEDIUM**

**Problem**:
- Legacy authentication plug being replaced by AuthPipeline
- Need clear deprecation timeline

**Current State**:
- ❌ No @deprecated annotation on CheckAclAuth plug

**Implementation Strategy**:
- Add @deprecated annotation with removal date
- Document migration path to AuthPipeline
- Schedule removal after migration complete

**Expected Impact**: Clear migration path for legacy code

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

### 33. 🔄 Enable FallbackController
**Goal**: Enable action_fallback WandererAppWeb.FallbackController in every API controller and delete manual put_status/2 + json/2 error branches.

**Status**: **PARTIALLY COMPLETE** - Some controllers use it, others don't

**Priority**: **MEDIUM**

**Problem**:
- Inconsistent error handling across controllers
- Manual error response code duplication

**Current State**:
- ✅ FallbackController exists
- ✅ Some controllers use action_fallback (e.g., MapSystemApiController)
- ❌ Not all API controllers have been updated

**Implementation Strategy**:
- Add action_fallback to all API controllers
- Remove manual error handling branches
- Ensure consistent error response format

**Expected Impact**: Consistent error handling, less code duplication

---

### 34. ✅ Extract OpenAPI Schemas
**Goal**: Extract repeated OpenAPI structs into WandererAppWeb.Schemas and reference them; remove in-controller schema definitions.

**Status**: **COMPLETED** - Created centralized schema module

**Priority**: **MEDIUM** (quick win)

**Problem**:
- OpenAPI schema definitions duplicated across controllers
- ~15% of controller LOC is schema definitions

**Implementation Summary**:
- ✅ Created `WandererAppWeb.Schemas` module with common schema helpers
- ✅ Added reusable schema functions for CRUD operations
- ✅ Centralized error response schemas
- ✅ Added helper functions for common patterns (timestamps, UUIDs, etc.)
- ✅ Refactored example controllers to use centralized schemas
- ✅ Added `standard_responses` helper for consistent error handling

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

### 42. ✅ Delete CheckAclApiKey (Quick Win)
**Goal**: Delete CheckAclApiKey immediately (zero references) and ensure the test suite passes.

**Status**: **COMPLETED** - Deleted successfully, all tests pass

**Problem**:
- Dead code with zero references
- Easy removal

**Implementation Strategy**:
- Delete CheckAclApiKey plug
- Run test suite to confirm
- Commit immediately

**Expected Impact**: Cleaner codebase

---

### 43. ✅ Centralize OpenAPI Schemas (Quick Win)
**Goal**: Centralise shared OpenAPI schemas today (≈ ½ day effort) to cut controller LOC by ~15%.

**Status**: **COMPLETED** - Same as #34

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

### 44. 🔄 Complete AuthPipeline Migration (Quick Win)
**Goal**: Finish swapping every router pipeline to AuthPipeline (≈ 1 day) and commit.

**Status**: **INCOMPLETE** - Same as #27

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

## Summary Status

### ✅ Completed (6)
- #25: Mock Map Server State Management
- #26: Comprehensive API Authentication Fixtures
- #28: Secure Token Comparison
- #34/#43: Extract/Centralize OpenAPI Schemas
- #42: Delete CheckAclApiKey

### 🔄 In Progress / Partially Complete (2)
- #33: Enable FallbackController (some controllers updated)
- #27/#44: AuthPipeline Migration (module exists, router not migrated)

### ❌ Not Started (6)
- #29: Remove AssignMapOwner Plug
- #30: Deprecate CheckAclAuth
- #32: Legacy Controller Deprecation
- #35: Standardize Input Validation
- #36: Simplify API Map Pipeline
- #37: Feature Flag Integration
- #39-41: Various lower priority items