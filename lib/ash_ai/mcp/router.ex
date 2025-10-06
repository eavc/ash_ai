if Code.ensure_loaded?(Plug) do
  defmodule AshAi.Mcp.Router do
    @moduledoc """
    MCP Router implementing the RPC functionality over HTTP.

    This router handles HTTP requests according to the Model Context Protocol specification.

    ## Usage

    ```elixir
    forward "/mcp", AshAi.Mcp.Router, tools: [:tool1, :tool2], otp_app: :my_app
    ```
    """

    use Plug.Router, copy_opts_to_assign: :router_opts

    require Logger
    alias AshAi.Mcp.Server

    @protocol_header "mcp-protocol-version"

    # CORS support for browser-based MCP clients (e.g., MCP Inspector)
    # Only enabled if Corsica is available
    if Code.ensure_loaded?(Corsica) do
      plug(Corsica,
        origins: "*",
        allow_methods: ["GET", "POST", "DELETE", "OPTIONS"],
        allow_headers: [
          "content-type",
          "authorization",
          "mcp-protocol-version",
          "mcp-session-id"
        ],
        expose_headers: ["mcp-protocol-version", "www-authenticate"],
        max_age: 3600
      )
    end

    # Discovery metadata must remain publicly readable so clients can learn how to
    # authenticate before negotiating the MCP session.
    plug(AshAi.Mcp.Auth.ResourceMetadata)

    plug(:validate_protocol_version)
    plug(AshAi.Mcp.Auth.OAuthBearerPlug)

    # Parse the request body for JSON
    plug(Plug.Parsers,
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: Jason
    )

    plug(:match)
    plug(:dispatch)

    post "/" do
      session_id = get_session_id(conn)

      Server.handle_post(conn, conn.params, session_id, conn.assigns.router_opts)
    end

    get "/" do
      session_id = get_session_id(conn)

      Server.handle_get(conn, session_id)
    end

    delete "/" do
      session_id = get_session_id(conn)

      Server.handle_delete(conn, session_id)
    end

    # Default route
    match _ do
      send_resp(conn, 404, "Not found")
    end

    # Helper to extract the session ID from headers
    defp get_session_id(conn) do
      case get_req_header(conn, "mcp-session-id") do
        [session_id | _] -> session_id
        [] -> nil
      end
    end

    defp validate_protocol_version(conn, _) do
      # Allow discovery unauthenticated and without protocol negotiation
      if conn.request_path == "/.well-known/oauth-protected-resource" do
        conn
      else
        opts = conn.assigns[:router_opts] || []
        # Only enforce protocol header when configured for production settings
        # (e.g., when public_base_url is provided). This keeps dev/minimal setups working
        # while allowing strict enforcement in real deployments.
        if Keyword.has_key?(opts, :public_base_url) do
          expected_version =
            case conn.assigns[:router_opts] do
              nil -> "2025-06-18"
              opts -> Keyword.get(opts, :protocol_version_statement, "2025-06-18")
            end

          case get_req_header(conn, @protocol_header) do
            [^expected_version | _] ->
              conn

            [] ->
              Logger.warning("MCP protocol negotiation failure: missing header")

              body =
                Server.json_rpc_error_response(
                  nil,
                  -32_600,
                  "Invalid request: MCP-Protocol-Version header is required",
                  %{"reason" => "missing_protocol_version"}
                )

              conn
              |> Plug.Conn.put_resp_header(@protocol_header, expected_version)
              |> Plug.Conn.put_resp_header("content-type", "application/json")
              |> Plug.Conn.resp(400, body)
              |> Plug.Conn.halt()

            [provided | _] ->
              Logger.warning(
                "MCP protocol negotiation failure: unsupported version (received: #{provided})"
              )

              body =
                Server.json_rpc_error_response(
                  nil,
                  -32_600,
                  "Invalid request: Unsupported MCP protocol version #{provided}",
                  %{"reason" => "unsupported_protocol_version", "supported" => [expected_version]}
                )

              conn
              |> Plug.Conn.put_resp_header(@protocol_header, expected_version)
              |> Plug.Conn.put_resp_header("content-type", "application/json")
              |> Plug.Conn.resp(426, body)
              |> Plug.Conn.halt()
          end
        else
          conn
        end
      end
    end
  end
end
