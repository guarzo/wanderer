# Template API Testing Scripts

This directory contains a suite of test scripts for validating the Template API functionality in the Wanderer application.

## Overview

The template API testing scripts verify different aspects of template functionality including:
- Creating, reading, updating, and deleting templates
- Listing templates with different query parameters
- Applying templates to maps
- Error handling and validation

## Test Scripts

### 1. template_api_tests.sh

**Purpose**: Comprehensive tests for Template API endpoints

This is the main template test script that covers:
- Template listing with different params (map_id, slug, etc.)
- Template creation through various endpoints
- Template CRUD operations
- Template application to maps

**Usage**:
```
./template_api_tests.sh         # Run tests without debug output
DEBUG=1 ./template_api_tests.sh # Run tests with debug output
```

### 2. template_basics_tests.sh

**Purpose**: Basic template operations focusing on core functionality

Tests more focused use cases:
- Creating a simple template
- Creating a template from an existing map
- Updating template metadata
- Testing basic template application

**Usage**:
```
./template_basics_tests.sh
```

### 3. template_operations_test.sh

**Purpose**: Tests specific operations like filtering and re-applying templates

Focuses on:
- Testing filtering templates by author and category
- Testing re-applying the same template multiple times

**Usage**:
```
./template_operations_test.sh
```

### 4. template_triangle_tests.sh

**Purpose**: Tests a real-world template with systems and connections

Creates and applies a template with:
- Three connected systems forming a triangle
- Verifies that all systems appear properly after application

**Usage**:
```
./template_triangle_tests.sh
```

### 5. template_error_tests.sh

**Purpose**: Tests error handling and validation in the Template API

Tests cover:
- Missing required fields
- Malformed JSON
- Invalid data types
- Deletion of non-existent templates
- Application of non-existent templates

**Usage**:
```
./template_error_tests.sh
```

## Common Utilities

All test scripts use the `utils.sh` file that provides:
- HTTP request handling
- Response parsing
- Test execution framework
- Common verification helpers

## Running All Tests

To run all template tests:

```bash
# Run all template tests
for test in template_*.sh; do
  echo "Running $test..."
  ./$test
  echo "------------------------"
done
```

## API Compatibility

The tests are designed to verify the standardized API paths as well as legacy endpoints, ensuring backward compatibility as the API evolves.

## Cleanup

All test scripts include cleanup code to remove any templates they create, preventing test data accumulation in the database. Typically, they:
1. Track created template IDs in an array
2. Delete these templates in a cleanup function executed at script exit 