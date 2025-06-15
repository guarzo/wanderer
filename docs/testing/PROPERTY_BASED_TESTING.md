# Property-Based Testing Guide

## Overview

Property-based testing complements our existing example-based tests by automatically generating hundreds of random inputs to test edge cases and boundary conditions that would be impractical to test manually.

## Architecture

### Test Structure

Property-based tests are organized in the `test/property/` directory and tagged with `@moduletag :property` to enable selective execution.

```elixir
defmodule WandererApp.SystemsPropertyTest do
  use WandererApp.ApiCase
  use ExUnitProperties
  
  import StreamData
  
  @moduletag :property
  @moduletag :api
  
  property "API handles various system IDs gracefully" do
    check all system_id <- solar_system_id_generator(),
              max_runs: 50 do
      # Test logic here
    end
  end
end
```

### Running Property Tests

```bash
# Run all property-based tests
mix test.property

# Run specific property test module
mix test test/property/systems_property_test.exs

# Run with verbose output to see generated values
mix test test/property/systems_property_test.exs --trace
```

## Test Categories

### 1. API Parameter Validation Tests

These tests validate that APIs handle various input formats gracefully:

- **Valid Inputs**: Should succeed or fail with business logic reasons
- **Invalid Inputs**: Should be rejected with appropriate error codes (400/422)
- **Edge Cases**: Boundary values, empty strings, null values
- **Security Cases**: SQL injection attempts, XSS payloads

### 2. State Transition Tests

For resources with state (like connection mass/time status):

- **Valid Transitions**: Should succeed and update state correctly
- **Invalid Transitions**: Should be rejected (e.g., can't improve wormhole status)
- **Lifecycle Testing**: Full progression through multiple states

### 3. Boundary Condition Tests

Test limits and edge cases:

- **Numeric Boundaries**: Min/max values for system IDs, positions
- **String Boundaries**: Empty strings, maximum length strings, Unicode
- **Collection Boundaries**: Empty lists, single items, maximum items

## Generator Patterns

### Common Generators

```elixir
# EVE Online System IDs (valid range)
defp solar_system_id_generator do
  oneof([
    integer(30000000..31999999),  # Valid range
    integer(29999990..30000010),  # Edge cases
    member_of([30000142, 30000144])  # Common test values
  ])
end

# Optional strings with various edge cases
defp optional_string_generator(max_length) do
  oneof([
    constant(nil),
    string(:alphanumeric, max_length: max_length),
    constant(""),  # Empty string
    constant(String.duplicate("a", max_length)),  # Max length
    member_of(["<script>", "'; DROP TABLE"])  # Security test cases
  ])
end

# Status values (0=fresh, 1=half/eol, 2=critical/collapsed)
defp status_generator do
  oneof([
    member_of([0, 1, 2]),  # Valid values
    integer(-5..-1),       # Invalid negative
    integer(3..10),        # Invalid high
    constant(nil),         # Invalid type
    constant("fresh")      # Invalid type
  ])
end
```

### Validation Helper Pattern

```elixir
# Separate validation logic for clarity
defp valid_system_id?(id) when is_integer(id) do
  id >= 30000000 and id <= 31999999
end
defp valid_system_id?(_), do: false

# Use in property tests
property "API validates system IDs properly" do
  check all system_id <- system_id_generator() do
    response = create_system_request(system_id)
    
    if valid_system_id?(system_id) do
      assert response.status in [200, 201]
    else
      assert response.status in [400, 422]
    end
  end
end
```

## Best Practices

### 1. Test Strategy

- **Start Simple**: Begin with basic parameter validation
- **Add Complexity**: Progress to state transitions and business logic
- **Focus on Boundaries**: Emphasize edge cases over happy paths
- **Complement Example Tests**: Don't replace, but enhance existing tests

### 2. Generator Design

- **Include Valid Cases**: Ensure some generated inputs are valid
- **Target Edge Cases**: Focus on boundary values and error conditions
- **Security Testing**: Include common attack vectors (SQL injection, XSS)
- **Type Boundaries**: Test wrong types, not just wrong values

### 3. Test Structure

- **Clear Property Statements**: Each property should test one logical assertion
- **Reasonable Max Runs**: Balance coverage with test execution time (20-100 runs)
- **Conditional Assertions**: Use validation helpers to determine expected behavior
- **Informative Failure Messages**: Include context about what was being tested

### 4. Performance Considerations

- **Timeout Management**: Use `@tag timeout: 30_000` for property tests
- **Limited Max Runs**: Start with 20-50 runs, increase if needed
- **Generator Efficiency**: Avoid overly complex generators that slow test execution
- **Parallel Execution**: Property tests can run in parallel with other test types

## Integration with Existing Tests

### Test Pyramid Integration

```
Property Tests (:property) → Boundary conditions and edge cases
     ↓
API Tests (:api)          → Full HTTP request/response testing
     ↓
Ash Tests (:ash)          → Resource integration with database
     ↓
Unit Tests (:unit)        → Fast, isolated, mocked dependencies
```

### Complementary Coverage

- **Example Tests**: Known important scenarios, happy paths, specific bugs
- **Property Tests**: Unknown edge cases, boundary conditions, random combinations
- **Integration Tests**: Real-world usage patterns, complex workflows

### Selective Execution

```bash
# Fast feedback loop - unit tests only
mix test.unit

# API validation including boundaries
mix test.api && mix test.property

# Full test suite
mix test
```

## Implementation Examples

### Systems API Property Tests

```elixir
property "POST systems handles various coordinates" do
  check all position_x <- position_generator(),
            position_y <- position_generator(),
            max_runs: 40 do
    
    params = %{"position_x" => position_x, "position_y" => position_y}
    response = post_system(params)
    
    cond do
      valid_position?(position_x) and valid_position?(position_y) ->
        assert response.status in [200, 201]
      true ->
        assert response.status in [400, 422]
    end
  end
end
```

### ACL Member Property Tests

```elixir
property "ACL member roles follow hierarchy rules" do
  check all role <- acl_role_generator(),
            target_role <- acl_role_generator(),
            max_runs: 25 do
    
    # Create member with initial role
    create_response = create_member(role)
    
    if create_response.status == 201 do
      # Attempt role change
      update_response = update_member_role(target_role)
      
      if valid_role_transition?(role, target_role) do
        assert update_response.status == 200
      else
        assert update_response.status in [400, 422]
      end
    end
  end
end
```

## Debugging Property Test Failures

### Common Failure Patterns

1. **Shrinking Issues**: StreamData shows minimal failing case
2. **Timeout Failures**: Tests running too long with complex generators
3. **Authorization Failures**: Generated invalid auth tokens or missing permissions
4. **Database Conflicts**: Concurrent property tests affecting each other

### Debugging Techniques

```elixir
# Add logging to see generated values
property "debug example" do
  check all value <- my_generator() do
    IO.inspect(value, label: "Generated")
    # Test logic
  end
end

# Use smaller max_runs during debugging
property "debug with fewer runs", %{max_runs: 5} do
  # Test logic
end

# Test specific edge cases found by property testing
test "regression test for edge case" do
  # Test the specific case that was found by property testing
end
```

## Future Enhancements

### Planned Additions

1. **Model-Based Testing**: State machine testing for complex workflows
2. **Performance Property Tests**: Response time boundaries and resource usage
3. **Concurrency Property Tests**: Race condition detection
4. **Contract Testing**: API specification compliance verification

### Integration Opportunities

- **CI Pipeline**: Run property tests in dedicated CI job
- **Nightly Runs**: Extended property test runs with higher max_runs
- **Regression Detection**: Save failing cases as regression tests
- **Performance Baselines**: Property tests for performance characteristics

## Resources

- [StreamData Documentation](https://hexdocs.pm/stream_data/)
- [ExUnitProperties Guide](https://hexdocs.pm/stream_data/ExUnitProperties.html)
- [Property-Based Testing Patterns](https://propertesting.com/)
- [Elixir Property Testing Best Practices](https://blog.appsignal.com/2021/11/16/property-based-testing-in-elixir-using-stream-data.html)