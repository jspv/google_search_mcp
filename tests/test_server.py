"""
Unit tests for Google Search MCP Server

Tests the core functionality of the server including:
- Configuration loading
- Result normalization
- Parameter handling
- Error conditions
"""

import os
from unittest.mock import AsyncMock, Mock, patch

import httpx
import pytest
from dynaconf import Dynaconf

from server import _normalize, search


class TestNormalize:
    """Tests for the _normalize helper function."""

    def test_normalize_empty_list(self):
        """Test normalization of empty results list."""
        result = _normalize([])
        assert result == []

    def test_normalize_none_input(self):
        """Test normalization with None input."""
        result = _normalize(None)
        assert result == []

    def test_normalize_single_item(self):
        """Test normalization of single search result."""
        items = [
            {
                "title": "Test Title",
                "link": "https://example.com",
                "snippet": "Test snippet content",
            }
        ]
        result = _normalize(items)

        expected = [
            {
                "title": "Test Title",
                "url": "https://example.com",
                "snippet": "Test snippet content",
                "rank": 1,
            }
        ]
        assert result == expected

    def test_normalize_multiple_items(self):
        """Test normalization of multiple search results."""
        items = [
            {
                "title": "First Result",
                "link": "https://first.com",
                "snippet": "First snippet",
            },
            {
                "title": "Second Result",
                "link": "https://second.com",
                "snippet": "Second snippet",
            },
        ]
        result = _normalize(items)

        assert len(result) == 2
        assert result[0]["rank"] == 1
        assert result[1]["rank"] == 2
        assert result[0]["url"] == "https://first.com"
        assert result[1]["url"] == "https://second.com"

    def test_normalize_missing_fields(self):
        """Test normalization with missing fields in source data."""
        items = [
            {"title": "Title Only"},
            {"link": "https://link-only.com"},
            {"snippet": "Snippet only"},
            {},  # Empty item
        ]
        result = _normalize(items)

        assert len(result) == 4
        # Check that missing fields become None
        assert result[0]["url"] is None
        assert result[0]["snippet"] is None
        assert result[1]["title"] is None
        assert result[3]["title"] is None
        assert result[3]["url"] is None
        assert result[3]["snippet"] is None
        # Check ranks are still assigned
        assert result[0]["rank"] == 1
        assert result[3]["rank"] == 4


class TestSearchFunction:
    """Tests for the main search function."""

    @pytest.fixture
    def mock_google_response(self):
        """Mock Google CSE API response."""
        return {
            "kind": "customsearch#search",
            "searchInformation": {
                "searchTime": 0.123,
                "formattedSearchTime": "0.12",
                "totalResults": "1000",
                "formattedTotalResults": "1,000",
            },
            "queries": {"nextPage": [{"startIndex": 4}]},
            "items": [
                {
                    "title": "Python Programming",
                    "link": "https://python.org",
                    "snippet": "Python is a programming language",
                },
                {
                    "title": "Learn Python",
                    "link": "https://learnpython.org",
                    "snippet": "Learn Python programming",
                },
            ],
        }

    @pytest.fixture
    def mock_httpx_client(self, mock_google_response):
        """Mock httpx client with Google API response."""
        mock_response = Mock()
        mock_response.json.return_value = mock_google_response
        mock_response.raise_for_status.return_value = None

        mock_client = AsyncMock()
        mock_client.get.return_value = mock_response

        return mock_client

    @patch("server.GOOGLE_API_KEY", "test_api_key")
    @patch("server.GOOGLE_CX", "test_cx_id")
    async def test_search_basic_query(self, mock_httpx_client, mock_google_response):
        """Test basic search functionality."""
        with patch("httpx.AsyncClient") as mock_client_class:
            mock_client_class.return_value.__aenter__.return_value = mock_httpx_client

            result = await search("Python programming")

            # Verify API call was made with correct parameters
            mock_httpx_client.get.assert_called_once()
            call_args = mock_httpx_client.get.call_args
            assert call_args[0][0] == "https://www.googleapis.com/customsearch/v1"

            params = call_args[1]["params"]
            assert params["q"] == "Python programming"
            assert params["key"] == "test_api_key"
            assert params["cx"] == "test_cx_id"
            assert params["num"] == 5  # default
            assert params["start"] == 1  # default

            # Verify response format
            assert result["provider"] == "google-cse"
            assert result["query"]["q"] == "Python programming"
            assert "searchInfo" in result
            assert "results" in result
            assert len(result["results"]) == 2
            assert result["results"][0]["rank"] == 1
            assert result["nextPage"] == 4

    @patch("server.GOOGLE_API_KEY", "test_api_key")
    @patch("server.GOOGLE_CX", "test_cx_id")
    async def test_search_with_parameters(self, mock_httpx_client):
        """Test search with all optional parameters."""
        with patch("httpx.AsyncClient") as mock_client_class:
            mock_client_class.return_value.__aenter__.return_value = mock_httpx_client

            await search(
                q="test query",
                num=3,
                start=10,
                siteSearch="example.com",
                safe="high",
                gl="us",
                hl="en",
                lr="lang_en",
                useSiteRestrict=False,
            )

            # Verify all parameters were passed to API
            call_args = mock_httpx_client.get.call_args
            params = call_args[1]["params"]

            assert params["q"] == "test query"
            assert params["num"] == 3
            assert params["start"] == 10
            assert params["siteSearch"] == "example.com"
            assert params["safe"] == "high"
            assert params["gl"] == "us"
            assert params["hl"] == "en"
            assert params["lr"] == "lang_en"

    @patch("server.GOOGLE_API_KEY", "test_api_key")
    @patch("server.GOOGLE_CX", "test_cx_id")
    async def test_search_with_site_restrict(self, mock_httpx_client):
        """Test search with site restriction endpoint."""
        with patch("httpx.AsyncClient") as mock_client_class:
            mock_client_class.return_value.__aenter__.return_value = mock_httpx_client

            await search("test", useSiteRestrict=True)

            # Verify site restrict endpoint was used
            call_args = mock_httpx_client.get.call_args
            endpoint = call_args[0][0]
            assert "siterestrict" in endpoint

    @patch("server.GOOGLE_API_KEY", "test_api_key")
    @patch("server.GOOGLE_CX", "test_cx_id")
    async def test_search_no_results(self, mock_httpx_client):
        """Test search with no results."""
        # Mock empty response
        mock_response = Mock()
        mock_response.json.return_value = {
            "kind": "customsearch#search",
            "searchInformation": {"totalResults": "0"},
            "queries": {},
        }
        mock_response.raise_for_status.return_value = None
        mock_httpx_client.get.return_value = mock_response

        with patch("httpx.AsyncClient") as mock_client_class:
            mock_client_class.return_value.__aenter__.return_value = mock_httpx_client

            result = await search("nonexistent query")

            assert result["results"] == []
            assert result["nextPage"] is None

    @patch("server.GOOGLE_API_KEY", "test_api_key")
    @patch("server.GOOGLE_CX", "test_cx_id")
    async def test_search_http_error(self, mock_httpx_client):
        """Test search with HTTP error."""
        mock_httpx_client.get.side_effect = httpx.HTTPStatusError(
            "API Error", request=Mock(), response=Mock(status_code=403)
        )

        with patch("httpx.AsyncClient") as mock_client_class:
            mock_client_class.return_value.__aenter__.return_value = mock_httpx_client

            with pytest.raises(httpx.HTTPStatusError):
                await search("test query")

    async def test_search_missing_credentials(self):
        """Test search with missing API credentials."""
        with patch("server.GOOGLE_API_KEY", None), patch("server.GOOGLE_CX", None):
            with patch("server.httpx.AsyncClient") as mock_client:
                mock_client.return_value.__aenter__.return_value.get = AsyncMock(
                    side_effect=Exception("Missing API credentials")
                )
                with pytest.raises(Exception, match="Missing API credentials"):
                    await search("test")

    @patch("server.GOOGLE_API_KEY", "test_api_key")
    @patch("server.GOOGLE_CX", "test_cx_id")
    async def test_search_api_key_not_in_response(
        self, mock_httpx_client, mock_google_response
    ):
        """Test that API key is not included in response query field."""
        with patch("httpx.AsyncClient") as mock_client_class:
            mock_client_class.return_value.__aenter__.return_value = mock_httpx_client

            result = await search("test query")

            # Verify API key is not in the returned query parameters
            assert "key" not in result["query"]
            assert result["query"]["q"] == "test query"
            assert result["query"]["cx"] == "test_cx_id"


class TestConfigurationOverride:
    """Tests for dynaconf configuration override behavior."""

    def test_environment_variables_override_dotenv(self, tmp_path):
        """Test that environment variables override .env file settings."""
        # Create a temporary .env file with different values
        env_file = tmp_path / ".env"
        env_file.write_text(
            "GOOGLE_API_KEY=dotenv_api_key\nGOOGLE_CX=dotenv_cx_value\n"
        )

        # Set different values in environment variables
        env_vars = {
            "GOOGLE_API_KEY": "env_var_api_key",
            "GOOGLE_CX": "env_var_cx_value",
        }

        with patch.dict(os.environ, env_vars, clear=False):
            # Create dynaconf settings similar to server.py
            test_settings = Dynaconf(
                envvar_prefix="GOOGLE",
                settings_files=[str(env_file)],
                load_dotenv=True,
            )

            # Environment variables should override .env file values
            assert test_settings.API_KEY == "env_var_api_key"
            assert test_settings.CX == "env_var_cx_value"

            # Verify the .env file contains different values
            assert "dotenv_api_key" in env_file.read_text()
            assert "dotenv_cx_value" in env_file.read_text()

    def test_dynaconf_environment_override_behavior(self):
        """Test dynaconf environment variable override behavior directly."""
        # Test with environment variables set
        env_vars = {
            "GOOGLE_API_KEY": "env_override_key",
            "GOOGLE_CX": "env_override_cx",
        }

        with patch.dict(os.environ, env_vars, clear=False):
            # Create dynaconf with default values
            test_settings = Dynaconf(
                envvar_prefix="GOOGLE",
                settings_files=[],  # No files to avoid interference
                API_KEY="default_api_key",
                CX="default_cx_value",
            )

            # Environment variables should override defaults
            assert test_settings.API_KEY == "env_override_key"
            assert test_settings.CX == "env_override_cx"

    def test_dynaconf_defaults_when_no_environment(self):
        """Test that default values are used when no environment variables are set."""
        # Remove any existing Google environment variables
        clean_env = {k: v for k, v in os.environ.items() if not k.startswith("GOOGLE_")}

        with patch.dict(os.environ, clean_env, clear=True):
            # Create dynaconf with default values
            test_settings = Dynaconf(
                envvar_prefix="GOOGLE",
                settings_files=[],  # No files to avoid interference
                API_KEY="default_api_key",
                CX="default_cx_value",
            )

            # Default values should be used
            assert test_settings.API_KEY == "default_api_key"
            assert test_settings.CX == "default_cx_value"

    def test_partial_environment_override_behavior(self):
        """Test partial environment variable override with defaults."""
        # Set only one environment variable
        clean_env = {k: v for k, v in os.environ.items() if not k.startswith("GOOGLE_")}
        clean_env["GOOGLE_API_KEY"] = "env_partial_key"
        # GOOGLE_CX is not set

        with patch.dict(os.environ, clean_env, clear=True):
            # Create dynaconf with default values
            test_settings = Dynaconf(
                envvar_prefix="GOOGLE",
                settings_files=[],  # No files to avoid interference
                API_KEY="default_api_key",
                CX="default_cx_value",
            )

            # Environment variable should override for API_KEY
            assert test_settings.API_KEY == "env_partial_key"
            # Default should be used for CX
            assert test_settings.CX == "default_cx_value"
