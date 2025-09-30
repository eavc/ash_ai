defmodule AshAi.Mcp.ProtocolVersionTest do
  use AshAi.RepoCase, async: true
  import Plug.{Conn, Test}
  import ExUnit.CaptureLog

  alias AshAi.Mcp.Router

  @opts [
    tools: [],
    otp_app: :ash_ai,
    public_base_url: "https://example.invalid",
    oauth_required?: false
  ]
  @protocol "2025-06-18"

  describe "protocol header enforcement" do
    test "rejects requests missing the MCP-Protocol-Version header" do
      conn =
        :post
        |> conn("/", %{method: "initialize", id: "1", params: %{}})

      log =
        capture_log(fn ->
          response = Router.call(conn, @opts)
          send(self(), {:response, response})
        end)

      assert_received {:response, response}
      assert response.status == 400

      assert log =~ "MCP protocol negotiation failure"

      body = Jason.decode!(response.resp_body)
      assert get_in(body, ["error", "code"]) == -32_600
      assert get_in(body, ["error", "_meta", "reason"]) == "missing_protocol_version"
      assert get_resp_header(response, "mcp-protocol-version") == [@protocol]
    end

    test "rejects unsupported protocol versions" do
      conn =
        :post
        |> conn("/", %{method: "initialize", id: "2", params: %{}})
        |> put_req_header("mcp-protocol-version", "2024-11-05")

      log =
        capture_log(fn ->
          response = Router.call(conn, @opts)
          send(self(), {:response, response})
        end)

      assert_received {:response, response}
      assert response.status == 426
      assert log =~ "unsupported version"

      body = Jason.decode!(response.resp_body)
      assert get_in(body, ["error", "_meta", "reason"]) == "unsupported_protocol_version"
      assert get_in(body, ["error", "_meta", "supported"]) == [@protocol]
      assert get_resp_header(response, "mcp-protocol-version") == [@protocol]
    end

    test "echoes the negotiated protocol version" do
      conn =
        :post
        |> conn(
          "/",
          %{
            method: "initialize",
            id: "3",
            params: %{client: %{name: "test", version: "1.0.0"}}
          }
        )
        |> put_req_header("mcp-protocol-version", @protocol)

      response = Router.call(conn, @opts)

      assert response.status == 200
      assert get_resp_header(response, "mcp-protocol-version") == [@protocol]

      body = Jason.decode!(response.resp_body)
      assert get_in(body, ["result", "protocolVersion"]) == @protocol
    end
  end
end
