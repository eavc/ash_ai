defmodule AshAi.Mcp.SseTransportTest do
  use AshAi.RepoCase, async: true
  import Plug.{Conn, Test}

  alias AshAi.Mcp.Router

  @opts [
    tools: [],
    otp_app: :ash_ai,
    public_base_url: "https://example.invalid",
    oauth_required?: false,
    sse_keepalive_interval_ms: 5,
    sse_keepalive_max_count: 1
  ]
  @protocol "2025-06-18"

  setup do
    init_conn =
      :post
      |> conn("/", %{method: "initialize", id: "init", params: %{}})
      |> put_req_header("mcp-protocol-version", @protocol)

    response = Router.call(init_conn, @opts)
    session_id = List.first(get_resp_header(response, "mcp-session-id"))

    {:ok, session_id: session_id}
  end

  test "SSE handshake emits endpoint metadata", %{session_id: session_id} do
    conn =
      :get
      |> conn("/")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", @protocol)

    response = Router.call(conn, @opts)

    assert response.status == 200
    assert response.halted

    assert get_resp_header(response, "mcp-protocol-version") == [@protocol]
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "content-type") == ["text/event-stream"]

    assert response.resp_body =~ "event: endpoint"
    assert response.private[:ash_ai_sse_keepalive_limit] == 1
    assert response.private[:ash_ai_sse_keepalive_interval] == 5
    assert response.private[:ash_ai_sse_keepalive_count] == 1
    assert response.private[:ash_ai_sse_keepalive_error] == nil

    [_, data] = Regex.run(~r/data: (.+)\n\n/, response.resp_body)
    payload = Jason.decode!(data)

    assert payload["url"] =~ "/"

    meta = payload["_meta"]
    assert meta["endpoint"] == payload["url"]
    assert meta["sessionId"] == session_id
    assert is_binary(meta["timestamp"])
  end
end
