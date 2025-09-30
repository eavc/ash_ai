defmodule AshAi.Mcp.ToolResultTest do
  use AshAi.RepoCase, async: true
  import Plug.{Conn, Test}

  alias AshAi.Mcp.Router
  alias AshAi.Test.Music

  @opts [
    tools: [:list_artists],
    otp_app: :ash_ai,
    public_base_url: "https://example.invalid",
    oauth_required?: false
  ]
  @protocol "2025-06-18"

  setup do
    conn =
      :post
      |> conn(
        "/",
        %{
          method: "initialize",
          id: "init",
          params: %{
            client: %{
              name: "test_client",
              version: "1.0.0"
            }
          }
        }
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", @protocol)

    response = Router.call(conn, @opts)

    {:ok, session_id: List.first(get_resp_header(response, "mcp-session-id"))}
  end

  test "tools/list includes structured metadata" do
    conn =
      :post
      |> conn(
        "/",
        %{
          method: "tools/list",
          id: "list"
        }
      )
      |> put_req_header("mcp-protocol-version", @protocol)
      |> put_req_header("content-type", "application/json")

    response = Router.call(conn, @opts)

    result = response.resp_body |> Jason.decode!() |> get_in(["result"])

    tools = result["tools"]
    assert length(tools) == 1

    [tool] = tools
    assert tool["name"] == "list_artists"
    assert tool["title"] == "List Artists"
    assert tool["defaultContentType"] == "application/json"
    assert tool["outputSchema"]["anyOf"] |> is_list()

    meta = tool["_meta"]
    assert meta["category"] == "ArtistAfterAction"
    assert meta["version"] == "1.0.0"

    result_meta = result["_meta"]
    assert result_meta["count"] == 1
    assert is_binary(result_meta["timestamp"])
  end

  test "tool call emits structured result with schema and links", %{session_id: session_id} do
    Music.create_artist_after_action!(%{name: "Schema Artist", bio: "Schema"})

    conn =
      :post
      |> conn(
        "/",
        %{
          method: "tools/call",
          id: "success",
          params: %{
            name: "list_artists"
          }
        }
      )
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", @protocol)

    response = Router.call(conn, @opts)
    result = response.resp_body |> Jason.decode!() |> get_in(["result"])

    assert result["type"] == "tool_result"

    [content] = result["content"]
    assert content["type"] == "application/json"
    assert is_list(content["data"])
    assert Enum.any?(content["data"], &(&1["name"] == "Schema Artist"))

    schema = content["schema"]
    assert is_map(schema)
    assert Map.has_key?(schema, "anyOf")

    links = result["resourceLinks"]

    assert Enum.any?(links, &(&1["href"] == "https://example.invalid/artist-feed"))

    assert collection_link = Enum.find(links, &match?(%{"_meta" => %{"rel" => "collection"}}, &1))
    assert collection_link["type"] == "application/vnd.api+json"

    assert Enum.any?(links, fn link ->
             link["_meta"]["rel"] == "item" and link["type"] == "application/vnd.api+json"
           end)

    meta = result["_meta"]
    assert meta["sessionId"] == session_id
    assert meta["requestId"] == "success"
    assert is_integer(meta["processingTimeMs"]) and meta["processingTimeMs"] >= 0
    assert is_binary(meta["timestamp"])
  end

  test "tool failures emit tool_error payloads", %{session_id: session_id} do
    conn =
      :post
      |> conn(
        "/",
        %{
          method: "tools/call",
          id: "error",
          params: %{
            name: "list_artists",
            arguments: %{"result_type" => %{"aggregate" => "median"}}
          }
        }
      )
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", @protocol)

    response = Router.call(conn, @opts)
    result = response.resp_body |> Jason.decode!() |> get_in(["result"])

    assert result["type"] == "tool_error"
    error = result["error"]
    assert is_map(error)
    assert is_list(Map.get(error, "errors"))

    meta = result["_meta"]
    assert meta["sessionId"] == session_id
    assert meta["requestId"] == "error"
    assert is_integer(meta["processingTimeMs"]) and meta["processingTimeMs"] >= 0
  end
end
