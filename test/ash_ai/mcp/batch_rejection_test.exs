defmodule AshAi.Mcp.BatchRejectionTest do
  use AshAi.RepoCase, async: true
  import Plug.{Conn, Test}

  alias AshAi.Mcp.Router

  @opts [
    tools: [],
    otp_app: :ash_ai,
    public_base_url: "https://example.invalid",
    oauth_required?: false
  ]
  @protocol "2025-06-18"

  test "rejects JSON-RPC batch payloads" do
    payload =
      Jason.encode!([
        %{method: "initialize", id: "1", params: %{}},
        %{method: "initialize", id: "2", params: %{}}
      ])

    conn =
      :post
      |> conn("/", payload)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", @protocol)

    response = Router.call(conn, @opts)

    assert response.status == 200
    assert get_resp_header(response, "mcp-protocol-version") == [@protocol]

    body = Jason.decode!(response.resp_body)
    assert get_in(body, ["error", "code"]) == -32_600
    assert get_in(body, ["error", "_meta", "reason"]) == "json-rpc-batching-removed"
  end
end
