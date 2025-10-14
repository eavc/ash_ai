# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Mcp do
  @moduledoc """
  Model Context Protocol (MCP) implementation for Ash Framework.

  This module implements a [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server
  that integrates with Ash Framework, following the MCP [Streamable HTTP Transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#streamable-http) specification.

  ## Overview

  This MCP implementation provides:

  * A fully compliant MCP server with JSON-RPC message processing for the 2025-06-18 protocol
  * Session management with unique session IDs and structured SSE handshakes
  * Support for both JSON and Server-Sent Events (SSE) responses with protocol headers
  * Strict rejection of JSON-RPC batching per the 2025-06-18 specification
  * A foundation for integrating Ash resources with MCP clients through exposed tools
  * Integration with AshAi tools for AI-assisted operations

  ## Current Features

  * `initialize` and `shutdown` method handlers
  * Session management via GenServer processes
  * Support for streaming responses via SSE
  * Plug-compatible router for easy integration with Phoenix or any Plug application
  * Tool support for AshAi functions with structured `tool_result`/`tool_error` payloads
  * IdP-agnostic OAuth 2.1 bearer token enforcement via `AshAi.Mcp.Auth`

  ## Future Enhancements

  * Additional observability hooks for tool execution
  * Expanded transport adapters as the MCP specification evolves

  ## Integration

  ### With Phoenix

  ```elixir
  # In your Phoenix router
  forward "/mcp", AshAi.Mcp.Router

  # With tools enabled
  forward "/mcp", AshAi.Mcp.Router, tools: [:tool1, :tool2]
  ```

  ### With Any Plug-Based Application

  The MCP router is a standard Plug, so it can be integrated into any Plug-based application.
  You are responsible for hosting the Plug however you prefer.
  """
end
