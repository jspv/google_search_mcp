"""
Pytest configuration and shared fixtures for Google Search MCP Server tests.
"""

import os
from unittest.mock import patch

import pytest


@pytest.fixture(autouse=True)
def mock_env_vars():
    """Mock environment variables for all tests."""
    with patch.dict(
        os.environ,
        {
            "GOOGLE_API_KEY": "test_api_key_12345",
            "GOOGLE_CX": "test_cx_id_67890",
        },
    ):
        yield


@pytest.fixture
def sample_google_cse_response():
    """Standard Google CSE API response for testing."""
    return {
        "kind": "customsearch#search",
        "url": {
            "type": "application/json",
            "template": "https://www.googleapis.com/customsearch/v1?q={searchTerms}&num={count?}&start={startIndex?}&lr={language?}&safe={safe?}&cx={cx?}&sort={sort?}&filter={filter?}&gl={gl?}&cr={cr?}&googlehost={googleHost?}&c2coff={disableCnTwTranslation?}&hq={hq?}&hl={hl?}&siteSearch={siteSearch?}&siteSearchFilter={siteSearchFilter?}&exactTerms={exactTerms?}&excludeTerms={excludeTerms?}&linkSite={linkSite?}&orTerms={orTerms?}&relatedSite={relatedSite?}&dateRestrict={dateRestrict?}&lowRange={lowRange?}&highRange={highRange?}&searchType={searchType}&fileType={fileType?}&rights={rights?}&imgSize={imgSize?}&imgType={imgType?}&imgColorType={imgColorType?}&imgDominantColor={imgDominantColor?}&alt=json",
        },
        "queries": {
            "request": [
                {
                    "title": "Google Custom Search - test query",
                    "totalResults": "1000000",
                    "searchTerms": "test query",
                    "count": 3,
                    "startIndex": 1,
                    "inputEncoding": "utf8",
                    "outputEncoding": "utf8",
                    "safe": "off",
                    "cx": "test_cx_id_67890",
                }
            ],
            "nextPage": [
                {
                    "title": "Google Custom Search - test query",
                    "totalResults": "1000000",
                    "searchTerms": "test query",
                    "count": 3,
                    "startIndex": 4,
                    "inputEncoding": "utf8",
                    "outputEncoding": "utf8",
                    "safe": "off",
                    "cx": "test_cx_id_67890",
                }
            ],
        },
        "context": {"title": "Test Search Engine"},
        "searchInformation": {
            "searchTime": 0.234567,
            "formattedSearchTime": "0.23",
            "totalResults": "1000000",
            "formattedTotalResults": "1,000,000",
        },
        "items": [
            {
                "kind": "customsearch#result",
                "title": "Test Result 1",
                "htmlTitle": "Test <b>Result</b> 1",
                "link": "https://example.com/1",
                "displayLink": "example.com",
                "snippet": "This is the first test result snippet.",
                "htmlSnippet": "This is the first <b>test</b> result snippet.",
                "cacheId": "cache123",
                "formattedUrl": "https://example.com/1",
                "htmlFormattedUrl": "https://example.com/1",
            },
            {
                "kind": "customsearch#result",
                "title": "Test Result 2",
                "htmlTitle": "Test <b>Result</b> 2",
                "link": "https://example.com/2",
                "displayLink": "example.com",
                "snippet": "This is the second test result snippet.",
                "htmlSnippet": "This is the second <b>test</b> result snippet.",
                "cacheId": "cache456",
                "formattedUrl": "https://example.com/2",
                "htmlFormattedUrl": "https://example.com/2",
            },
        ],
    }


@pytest.fixture
def empty_google_cse_response():
    """Empty Google CSE API response for testing no results scenario."""
    return {
        "kind": "customsearch#search",
        "url": {
            "type": "application/json",
            "template": "https://www.googleapis.com/customsearch/v1?q={searchTerms}...",
        },
        "queries": {
            "request": [
                {
                    "title": "Google Custom Search - nonexistent",
                    "totalResults": "0",
                    "searchTerms": "nonexistent",
                    "count": 5,
                    "startIndex": 1,
                    "inputEncoding": "utf8",
                    "outputEncoding": "utf8",
                    "safe": "off",
                    "cx": "test_cx_id_67890",
                }
            ]
        },
        "context": {"title": "Test Search Engine"},
        "searchInformation": {
            "searchTime": 0.123456,
            "formattedSearchTime": "0.12",
            "totalResults": "0",
            "formattedTotalResults": "0",
        },
    }


# Pytest configuration
def pytest_configure(config):
    """Configure pytest with custom markers."""
    config.addinivalue_line("markers", "unit: marks tests as unit tests")
    config.addinivalue_line("markers", "slow: marks tests as slow running")


# Pytest collection configuration
def pytest_collection_modifyitems(config, items):
    """Auto-mark tests based on their location."""
    for item in items:
        # Mark unit tests
        if "test_server" in item.nodeid:
            item.add_marker(pytest.mark.unit)
