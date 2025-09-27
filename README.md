# Google Search MCP Server

A Model Context Protocol (MCP) server that provides Google Custom Search functionality.

## Configuration

This server uses [Dynaconf](https://www.dynaconf.com/) for configuration management, supporting both `.env` files and environment variables.

### Setup

1. Copy the example environment file:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and add your Google API credentials:
   ```bash
   GOOGLE_API_KEY=your_actual_api_key_here
   GOOGLE_CX=your_custom_search_engine_id_here
   ```

### Environment Variable Override

Environment variables will **override** `.env` file values when both are present. This allows for flexible deployment scenarios:

- **Development**: Use `.env` file for local development
- **Production**: Use environment variables for production deployment
- **CI/CD**: Environment variables can override defaults for testing

#### Example:

If your `.env` file contains:
```bash
GOOGLE_API_KEY=dev_key_from_file
```

And you set an environment variable:
```bash
export GOOGLE_API_KEY=prod_key_from_env
```

The server will use `prod_key_from_env` (environment variable takes precedence).

### Required Configuration

- `GOOGLE_API_KEY`: Your Google Custom Search API key
- `GOOGLE_CX`: Your Custom Search Engine ID

Get these from:
- API Key: [Google Cloud Console](https://console.developers.google.com/)
- Search Engine ID: [Google Custom Search](https://cse.google.com/cse/all)

## Usage

Run the server:
```bash
python server.py
```
