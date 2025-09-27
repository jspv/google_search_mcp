# Tests for Google Search MCP Server

This directory contains the test suite for the Google Search MCP Server.

## Test Structure

- `test_server.py` - Unit tests for server functions with comprehensive mocking
- `test_client.py` - Manual test client for interactive debugging
- `conftest.py` - Pytest configuration and shared fixtures

## Running Tests

```bash
# Install dev dependencies
uv sync --extra dev

# Run all tests (recommended)
uv run pytest

# Run unit tests only
uv run pytest -m unit

# Run with coverage
uv run pytest --cov=server --cov-report=term-missing

# Run with verbose output
uv run pytest -v
```

## Test Coverage

The test suite provides comprehensive coverage of all core functionality:

- ✅ **`_normalize()` function**: Edge cases, missing fields, empty inputs
- ✅ **`search()` function**: All parameters, error handling, API mocking  
- ✅ **Error scenarios**: HTTP errors, missing credentials, malformed responses
- ✅ **API integration**: Parameter validation and response parsing
- ✅ **Interactive testing**: Manual test client for debugging

All tests use proper mocking to avoid making real API calls during testing.