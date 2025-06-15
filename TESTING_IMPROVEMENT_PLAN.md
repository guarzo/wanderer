# Wanderer Testing Improvement Plan

## Executive Summary

This document outlines a comprehensive plan to improve the testing infrastructure of the Wanderer EVE Online mapping tool. The project currently has a solid foundation with 88% test pass rate (45/51 tests), but several key areas need enhancement to achieve production-ready testing coverage.

## Current State Analysis

### Testing Infrastructure Strengths
- **Comprehensive API Test Suite**: 51 tests covering REST endpoints with authentication
- **Multiple Test Layers**: Unit, integration, API, and manual testing approaches
- **Proper Test Isolation**: Ecto Sandbox and Mox for clean test environments
- **Good Organization**: Dedicated `/api-test` directory with structured test files
- **Authentication Testing**: Proper Bearer token and API key validation
- **Mock Infrastructure**: Established mocking for external dependencies

### Current Test Statistics
- **Total Tests**: 51 tests across 4 main test files
- **Pass Rate**: 88% (45 passing, 6 failing)
- **Test Types**: Authentication, CRUD operations, validation, integration workflows
- **Coverage Areas**: Map Systems API, Map Connections API, ACL API, Health checks

### Key Testing Gaps Identified

1. **External API Dependencies**: 6 failing tests due to EVE ESI API requirements
2. **Real-time Feature Testing**: Missing WebSocket/LiveView test coverage
3. **Performance Testing**: No load testing or performance benchmarks
4. **Security Testing**: Limited penetration testing coverage
5. **Contract Testing**: No API versioning or backwards compatibility tests
6. **Documentation**: Test coverage gaps in complex workflows

## Test Strategy Framework

### Four-Layer Test Pyramid

Based on the testing task list recommendations, we'll implement a clean test pyramid with four distinct layers:

#### 1️⃣ Fast Unit Tests (Pure Functions/Calculations)
- **Goal**: Test pure business logic and calculations in isolation
- **Scope**: Utility functions, calculations, data transformations
- **Mocking**: No external dependencies, no database
- **Runtime Budget**: <1 second for entire suite
- **Tag**: `:unit`

#### 2️⃣ Ash Action Tests (Resource Logic in Isolation)
- **Goal**: Test Ash resource actions, validations, and business rules
- **Scope**: Resource CRUD operations, changesets, validations
- **Mocking**: External APIs (ESI), but use real database with sandbox
- **Runtime Budget**: <10 seconds for entire suite
- **Tag**: `:ash`

#### 3️⃣ Phoenix Controller/Plug Tests (Public API Surface)
- **Goal**: Test HTTP endpoints, authentication, authorization, serialization
- **Scope**: Controller actions, plugs, API responses
- **Mocking**: External APIs, use real database and Phoenix
- **Runtime Budget**: <30 seconds for entire suite
- **Tag**: `:api`

#### 4️⃣ End-to-End Smoke Tests (Full Integration)
- **Goal**: Test critical user journeys with real environment
- **Scope**: Complete workflows, real external APIs (when available)
- **Mocking**: Minimal - only when external services unavailable
- **Runtime Budget**: <2 minutes for entire suite
- **Tag**: `:e2e`

## Implementation Plan

### Phase 1: Strengthen Public API Test Foundation (Priority: High)

#### 1.1 Unify Test Entry Points & Structure (Week 1)
**Goal**: Consolidate test infrastructure and eliminate dual Mix environments

**Files to Reorganize**:
```
# Move api-test/ to unified structure
api-test/ → test/api/           # Consolidate into main test tree
test/support/api_case.ex        # Update paths and configuration
mix.exs                         # Add unified test aliases
```

**Mix Aliases to Add**:
```elixir
"test.unit" => "mix test --only unit",
"test.ash" => "mix test --only ash", 
"test.api" => "mix test --only api",
"test.e2e" => "mix test --only e2e"
```

**Implementation Tasks**:
- Move `api-test/` directory to `test/api/` 
- Update `ApiCase` module paths and configuration
- Remove duplicate test environment configuration
- Add test tags (`:unit`, `:ash`, `:api`, `:e2e`) to existing tests
- Update documentation and scripts

**Success Criteria**:
- Single test tree with unified configuration
- Clear test layer separation via tags
- Simplified CI/CD pipeline setup

#### 1.2 Replace TestFactory with ExMachina-Ash (Week 1)
**Goal**: Use proper Ash factories instead of raw database inserts

**Files to Create/Replace**:
```
test/support/
├── factory.ex                 # New ExMachina-Ash factory
└── factory_helpers.ex         # Factory utility functions

# Remove old factory
api-test/support/test_factory.ex → DELETE
```

**Implementation Tasks**:
- Migrate from `Repo.insert_all/3` to `Ash.create!/2` calls
- Create proper ExMachina factories for all resources
- Use actor-aware actions where appropriate (`Ash.create!/3`)
- Maintain business rule validation during test data creation
- Add relationship factories for complex scenarios

**Success Criteria**:
- All test data creation uses Ash framework
- Business rules enforced during test setup
- Factory patterns support all existing test scenarios

#### 1.3 Mock External Dependencies (Week 2)
**Goal**: Achieve 100% test pass rate by eliminating external API dependencies

**Files to Create**:
```
lib/wanderer_app/esi/
├── mock.ex                    # Main EVE ESI API mock
└── behaviors/
    ├── character_behavior.ex  # Character lookup behavior
    ├── corporation_behavior.ex # Corporation lookup behavior
    └── alliance_behavior.ex   # Alliance lookup behavior

test/support/
├── esi_mock.ex               # Test-specific ESI mocks
└── esi_fixtures.ex           # Static test data for EVE entities
```

**Implementation Tasks**:
- Create mock implementations for all EVE ESI API calls
- Fix 6 failing ACL member tests that require character/corporation lookups
- Add comprehensive test fixtures for EVE Online entities
- Ensure mocks cover all authentication scenarios

**Success Criteria**:
- All 51 tests pass consistently
- No external API calls during test execution
- Comprehensive mock coverage for EVE ESI endpoints

#### 1.4 Harden ApiCase for Real CRUD Flows (Week 2)
**Goal**: Improve API test infrastructure for realistic testing

**Files to Enhance**:
```
test/support/
├── api_case.ex               # Enhanced API test case
├── open_api_assert.ex        # Contract validation macro
└── auth_helpers.ex           # Proper JWT authentication
```

**Implementation Tasks**:
- Update SQL sandbox for shared mode with `:async` tag
- Replace fake authentication with proper Guardian JWT tokens
- Add `json_response!/2` helper that raises on non-2xx responses
- Create `assert_conforms!/2` macro for OpenAPI spec validation
- Integrate with existing `WandererAppWeb.ApiSpec`

**Success Criteria**:
- Proper authentication using Guardian JWT
- Automatic OpenAPI schema validation
- Simplified happy-path assertions
- Better async test support

#### 1.5 Scaffold Golden-Path API Tests (Week 3)
**Goal**: Create comprehensive CRUD tests for core APIs using OpenAPI validation

**Files to Create**:
```
test/api/
├── maps_api_test.exs         # Map CRUD with schema validation
├── systems_api_test.exs      # System management tests
├── connections_api_test.exs  # Connection management tests
└── acls_api_test.exs         # ACL management tests
```

**Implementation Tasks**:
- Test all CRUD operations (GET, POST, PUT, DELETE)
- Use new ExMachina-Ash factories for test data
- Validate all responses against OpenAPI schemas
- Test both success and error scenarios
- Replace existing "401-only" tests with full coverage

**Success Criteria**:
- Complete CRUD test coverage for all public APIs
- All responses validated against OpenAPI schemas
- Golden-path tests serve as API documentation
- Higher confidence in API changes

#### 1.6 API Contract Testing (Week 3)
**Goal**: Ensure API stability and backwards compatibility

**Files to Create**:
```
api-test/contracts/
├── map_systems_contract_test.exs    # Map Systems API contracts
├── map_connections_contract_test.exs # Map Connections API contracts
├── acl_contract_test.exs            # ACL API contracts
├── response_schema_test.exs         # Response format validation
└── error_format_test.exs            # Error response standardization
```

**Implementation Tasks**:
- Define JSON schemas for all API responses
- Validate response structure consistency
- Test error response formats
- Document expected data structures
- Add API versioning tests

**Success Criteria**:
- All API responses conform to documented schemas
- Consistent error response formats
- Backwards compatibility validation

### Phase 2: Real-time Feature Testing (Priority: Medium)

#### 2.1 WebSocket/LiveView Testing (Week 4)
**Goal**: Test real-time collaborative features and WebSocket connections

**Files to Create**:
```
test/wanderer_app_web/live/
├── map_live_test.exs          # Map LiveView testing
├── system_live_test.exs       # System updates testing
├── connection_live_test.exs   # Connection real-time testing
└── collaboration_live_test.exs # Multi-user collaboration

test/wanderer_app_web/channels/
├── map_channel_test.exs       # WebSocket channel testing
└── presence_channel_test.exs  # User presence testing
```

**Implementation Tasks**:
- Test Phoenix LiveView component updates
- Validate WebSocket message handling
- Test real-time map collaboration
- Verify user presence tracking
- Test connection state synchronization

**Success Criteria**:
- Real-time updates work correctly
- WebSocket connections are stable
- Multi-user collaboration is tested
- Presence tracking is validated

#### 2.2 PubSub Integration Testing (Week 5)
**Goal**: Test internal message passing and GenServer coordination

**Files to Create**:
```
test/wanderer_app/map/
├── map_server_integration_test.exs  # GenServer testing
├── pubsub_integration_test.exs      # PubSub message flow
└── process_supervision_test.exs     # Supervision tree testing

test/wanderer_app/character/
└── character_tracking_test.exs      # Character location tracking
```

**Implementation Tasks**:
- Test GenServer map server operations
- Validate PubSub message routing
- Test process supervision and recovery
- Verify character tracking accuracy

**Success Criteria**:
- GenServer processes work correctly
- PubSub messages are delivered reliably
- Process supervision handles failures
- Character tracking is accurate

### Phase 3: Performance & Security Testing (Priority: Medium)

#### 3.1 Property-Based Testing (Week 6)
**Goal**: Add fuzz testing for API edge cases and input validation

**Files to Create**:
```
test/api/property/
├── maps_query_params_prop_test.exs    # Fuzz pagination/sorting
├── input_validation_prop_test.exs     # Fuzz input fields
└── api_resilience_prop_test.exs       # General API fuzzing
```

**Implementation Tasks**:
- Use StreamData to fuzz query parameters (pagination, sorting, filtering)
- Test that APIs never crash with malformed input
- Ensure all responses return proper HTTP status codes (2xx/4xx, not 5xx)
- Validate all responses conform to OpenAPI schemas
- Test boundary conditions and edge cases

**Success Criteria**:
- APIs handle all malformed input gracefully
- No server crashes from unexpected input
- Response schemas remain consistent under fuzzing
- Property-based tests catch edge cases missed by example-based tests

#### 3.2 Performance Test Suite (Week 6)
**Goal**: Establish performance baselines and identify bottlenecks

**Files to Create**:
```
test/performance/
├── api_load_test.exs           # API endpoint load testing
├── map_server_performance_test.exs # GenServer performance
├── database_performance_test.exs   # Database query optimization
└── websocket_performance_test.exs  # Real-time performance

config/
└── performance_test.exs        # Performance test configuration
```

**Implementation Tasks**:
- Create load tests for critical API endpoints
- Test GenServer performance under load
- Analyze database query performance
- Test WebSocket connection limits
- Establish performance benchmarks

**Success Criteria**:
- Performance baselines established
- Bottlenecks identified and documented
- Load testing infrastructure in place
- Performance regression detection

#### 3.2 Security Test Enhancement (Week 7)
**Goal**: Comprehensive security testing and vulnerability assessment

**Files to Create**:
```
test/security/
├── authentication_security_test.exs   # Auth bypass attempts
├── authorization_security_test.exs    # Permission escalation
├── input_validation_security_test.exs # Injection prevention
├── rate_limiting_test.exs             # DoS protection
└── session_security_test.exs          # Session management

test/security/scenarios/
├── sql_injection_test.exs     # SQL injection scenarios
├── xss_prevention_test.exs    # XSS attack prevention
└── csrf_protection_test.exs   # CSRF token validation
```

**Implementation Tasks**:
- Test authentication bypass scenarios
- Validate authorization controls
- Test input sanitization
- Verify rate limiting effectiveness
- Test session security

**Success Criteria**:
- Security vulnerabilities identified and fixed
- Comprehensive security test coverage
- Automated security regression testing
- Security best practices validated

### Phase 4: Test Infrastructure Improvements (Priority: Low)

#### 4.1 CI/CD Split & Coverage Gates (Week 8)
**Goal**: Implement granular CI pipeline with coverage enforcement

**Files to Create/Enhance**:
```
.github/workflows/
├── ci.yml                    # Matrix jobs for different test layers
├── performance.yml           # Performance test workflow  
└── security.yml              # Security test workflow

config/
├── coveralls.json           # Coverage configuration
└── test_reporting.exs       # Test reporting setup
```

**Implementation Tasks**:
- Create CI matrix jobs for each test layer:
  - `unit` job: runs `mix test.unit` 
  - `ash` job: runs `mix test.ash`
  - `api` job: runs `mix test.api`
  - `e2e` job: runs `mix test.e2e` (manual trigger only)
- Fail jobs if overall coverage < 85%
- Use `mix coveralls.github` for reporting
- Parallel execution for faster feedback
- Badge reporting for coverage and test status

**Success Criteria**:
- Fast feedback from unit tests (<1 min)
- Parallel execution of different test layers
- Coverage enforcement prevents regressions
- Clear CI pipeline status and reporting

#### 4.2 Document Hybrid End-to-End Suite (Week 9)
**Goal**: Document E2E testing approach and hybrid testing strategy

**Files to Create/Enhance**:
```
test/README.md               # Enhanced with E2E section
docs/testing/
├── API_TESTING_GUIDE.md     # API testing best practices
├── UNIT_TESTING_GUIDE.md    # Unit testing guidelines  
├── E2E_TESTING_GUIDE.md     # End-to-end testing guide
├── HYBRID_TESTING.md        # Hybrid testing with real APIs
└── TEST_DATA_MANAGEMENT.md  # Test data guidelines

test/examples/
├── api_test_examples.exs      # Example API tests
├── unit_test_examples.exs     # Example unit tests
└── e2e_test_examples.exs      # Example E2E tests
```

**Implementation Tasks**:
- Document when to run E2E tests locally (real `.env` credentials)
- Explain why E2E tests are excluded from CI by default
- Document `mix test --only e2e` usage patterns
- Create hybrid testing guide for real API integration
- Document test data management strategies
- Create contributor testing guidelines

**Success Criteria**:
- Clear E2E testing documentation
- Hybrid testing strategy documented
- Contributors understand when to use each test layer
- E2E test setup is straightforward

## Implementation Timeline

### Immediate Actions (Next 3 Weeks)
1. **Week 1**: Unify test structure and replace TestFactory with ExMachina-Ash
2. **Week 2**: Create EVE ESI API mocks and harden ApiCase infrastructure
3. **Week 3**: Scaffold golden-path API tests with OpenAPI validation

### Short-term Goals (Weeks 4-5)
4. **Week 4**: Add WebSocket/LiveView testing for real-time features
5. **Week 5**: Create PubSub integration tests and process supervision

### Medium-term Goals (Weeks 6-9)
6. **Week 6**: Add property-based testing and performance baselines
7. **Week 7**: Enhance security testing coverage
8. **Week 8**: Implement CI/CD matrix jobs with coverage gates
9. **Week 9**: Complete testing documentation and hybrid E2E guide

## Key Improvements from Testing Task List Integration

### Architectural Improvements
1. **Four-Layer Test Pyramid**: Clear separation of concerns with runtime budgets
2. **Unified Test Structure**: Single test tree instead of dual Mix environments
3. **ExMachina-Ash Integration**: Proper Ash framework usage in tests
4. **OpenAPI Contract Validation**: Automatic schema validation for all API responses

### Infrastructure Improvements  
1. **Granular CI Pipeline**: Matrix jobs for different test layers with fast feedback
2. **Property-Based Testing**: StreamData fuzzing for edge case discovery
3. **Enhanced ApiCase**: Proper Guardian JWT authentication and helpers
4. **Coverage Enforcement**: 85% coverage gate with detailed reporting

### Developer Experience Improvements
1. **Clear Test Commands**: `mix test.unit`, `mix test.api`, `mix test.e2e`
2. **Golden-Path Tests**: Complete CRUD coverage serving as living documentation
3. **Hybrid E2E Testing**: Real API integration when needed, mocked by default
4. **Contract-First Testing**: OpenAPI specs drive test validation

## Success Metrics

### Quantitative Goals
- **Test Pass Rate**: Achieve and maintain 100% pass rate
- **Code Coverage**: Increase from current level to >90%
- **Test Execution Time**: Keep full test suite under 5 minutes
- **API Response Time**: Establish performance baselines
- **Security Coverage**: 100% of security scenarios tested

### Qualitative Goals
- **Developer Confidence**: High confidence in making changes
- **Bug Prevention**: Catch issues before production
- **Documentation Quality**: Clear testing guidelines
- **Maintainability**: Easy to add new tests
- **CI/CD Integration**: Automated quality gates

## Resource Requirements

### Development Time
- **Phase 1**: ~3 weeks (24 developer days)
- **Phase 2**: ~2 weeks (16 developer days)
- **Phase 3**: ~2 weeks (16 developer days)
- **Phase 4**: ~2 weeks (16 developer days)
- **Total**: ~9 weeks (72 developer days)

### Infrastructure
- CI/CD pipeline setup and configuration
- Test database provisioning
- Performance testing environment
- Security scanning tools integration

## Risk Mitigation

### Technical Risks
- **External API Dependencies**: Mitigated by comprehensive mocking
- **Test Execution Time**: Addressed by parallel test execution
- **Test Data Management**: Solved by factory patterns
- **CI/CD Integration**: Phased rollout approach

### Project Risks
- **Resource Availability**: Prioritized approach allows partial completion
- **Scope Creep**: Clear phase boundaries and success criteria
- **Technical Debt**: Incremental improvements reduce risk

## Conclusion

This testing improvement plan provides a structured approach to achieving production-ready test coverage for the Wanderer application. By focusing on immediate pain points (external API dependencies) and building a solid foundation (API contract testing), the plan ensures both quick wins and long-term testing infrastructure improvements.

The phased approach allows for incremental progress while maintaining development velocity. Each phase builds upon the previous one, creating a comprehensive testing ecosystem that supports confident development and reliable production deployments.

## Next Steps

1. **Review and Approve**: Stakeholder review of the implementation plan
2. **Resource Allocation**: Assign development resources to Phase 1
3. **Begin Implementation**: Start with EVE ESI API mocking (Week 1)
4. **Progress Tracking**: Weekly progress reviews and plan adjustments
5. **Documentation Updates**: Keep this plan updated as implementation progresses