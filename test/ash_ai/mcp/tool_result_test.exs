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

  defp with_telemetry(events, fun) do
    handler_id = make_ref()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(self(), {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  test "tools/list includes structured metadata" do
    with_telemetry([[:ash_ai, :mcp, :tools, :list]], fn ->
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
      assert tool["outputSchema"]["anyOf"] |> is_list()

      meta = tool["_meta"]
      assert meta["category"] == "ArtistAfterAction"
      assert meta["version"] == "1.0.0"

      result_meta = result["_meta"]
      assert result_meta["count"] == 1
      assert is_binary(result_meta["timestamp"])
    end)

    assert_receive {
      :telemetry_event,
      [:ash_ai, :mcp, :tools, :list],
      %{duration: duration},
      %{count: 1}
    }

    assert duration >= 0
  end

  test "tool call emits structured result with schema and links", %{session_id: session_id} do
    Music.create_artist_after_action!(%{name: "Schema Artist", bio: "Schema"})

    with_telemetry([[:ash_ai, :mcp, :tools, :call]], fn ->
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

      assert result["isError"] == false

      [content] = result["content"]
      assert content["type"] == "text"
      assert is_binary(content["text"])

      # Verify the text content contains the artist data
      assert String.contains?(content["text"], "Schema Artist")

      links = result["resourceLinks"]

      assert Enum.any?(links, &(&1["href"] == "https://example.invalid/artist-feed"))

      assert collection_link =
               Enum.find(links, &match?(%{"_meta" => %{"rel" => "collection"}}, &1))

      assert collection_link["type"] == "application/vnd.api+json"

      assert Enum.any?(links, fn link ->
               link["_meta"]["rel"] == "item" and link["type"] == "application/vnd.api+json"
             end)

      meta = result["_meta"]
      assert meta["sessionId"] == session_id
      assert meta["requestId"] == "success"
      assert is_integer(meta["processingTimeMs"]) and meta["processingTimeMs"] >= 0
      assert is_binary(meta["timestamp"])
    end)

    assert_receive {
      :telemetry_event,
      [:ash_ai, :mcp, :tools, :call],
      %{duration: duration},
      %{status: :ok, tool: "list_artists"}
    }

    assert duration >= 0
  end

  test "tool failures emit tool_error payloads", %{session_id: session_id} do
    with_telemetry([[:ash_ai, :mcp, :tools, :call]], fn ->
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
    end)

    assert_receive {
      :telemetry_event,
      [:ash_ai, :mcp, :tools, :call],
      %{duration: duration},
      %{status: :error, reason: :tool_execution_error, tool: "list_artists"}
    }

    assert duration >= 0
  end

  test "tool result stays structured when public_base_url is absent", %{session_id: session_id} do
    Music.create_artist_after_action!(%{name: "No Base", bio: "Fallback"})

    # Temporarily clear MCP_PUBLIC_URL env var for this test
    original_env = System.get_env("MCP_PUBLIC_URL")
    System.delete_env("MCP_PUBLIC_URL")

    opts_without_base = Keyword.delete(@opts, :public_base_url)

    conn =
      :post
      |> conn(
        "/",
        %{
          method: "tools/call",
          id: "nobase",
          params: %{
            name: "list_artists"
          }
        }
      )
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", @protocol)

    response = Router.call(conn, opts_without_base)
    result = response.resp_body |> Jason.decode!() |> get_in(["result"])

    assert result["isError"] == false
    assert is_nil(result["resourceLinks"])

    [content] = result["content"]
    assert content["type"] == "text"
    assert is_binary(content["text"])

    # Restore original env var if it existed
    if original_env do
      System.put_env("MCP_PUBLIC_URL", original_env)
    end
  end
end
