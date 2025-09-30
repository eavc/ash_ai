defmodule AshAi.Mcp.ResponseBuilder do
  @moduledoc false

  require Logger

  @type timestamp :: String.t()

  @doc """
  Builds the MCP 2025-06-18 `tool_result` payload.
  """
  @spec tool_result(keyword()) :: map()
  def tool_result(opts) do
    %{
      "type" => "tool_result",
      "content" => [content(opts)],
      "resourceLinks" => Keyword.get(opts, :resource_links, []),
      "_meta" => meta(opts)
    }
  end

  @doc """
  Builds the MCP `tool_error` payload.
  """
  @spec tool_error(keyword()) :: map()
  def tool_error(opts) do
    error = Keyword.fetch!(opts, :error)

    %{
      "type" => "tool_error",
      "error" => error,
      "_meta" => meta(opts)
    }
  end

  @doc """
  Builds an MCP `elicitationRequest` payload used when tools need additional
  input from the client.
  """
  @spec elicitation_request(keyword()) :: map()
  def elicitation_request(opts) do
    %{
      "type" => "elicitationRequest",
      "id" => Keyword.fetch!(opts, :id),
      "prompt" => Keyword.fetch!(opts, :prompt),
      "schema" => Keyword.get(opts, :schema),
      "context" => Keyword.get(opts, :context, %{}),
      "_meta" => meta(opts)
    }
  end

  defp content(opts) do
    content = %{"type" => Keyword.fetch!(opts, :content_type)}
    schema = Keyword.get(opts, :schema)
    data = Keyword.get(opts, :data)

    content
    |> maybe_put("schema", schema)
    |> maybe_put("data", data)
  end

  defp meta(opts) do
    base_meta = %{
      "sessionId" => Keyword.get(opts, :session_id),
      "requestId" => Keyword.get(opts, :request_id),
      "timestamp" => Keyword.get(opts, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601()),
      "processingTimeMs" => processing_time_ms(opts)
    }

    meta_builder = Keyword.get(opts, :meta_builder)

    additional_meta =
      if is_function(meta_builder, 1) do
        invoke_meta_builder(meta_builder, opts)
      else
        %{}
      end

    base_meta
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Map.merge(additional_meta)
  end

  defp invoke_meta_builder(builder, opts) do
    builder.(%{
      data: Keyword.get(opts, :data),
      session_id: Keyword.get(opts, :session_id),
      request_id: Keyword.get(opts, :request_id)
    })
  rescue
    exception ->
      Logger.warning("tool meta_builder failed: #{Exception.message(exception)}")
      %{}
  end

  defp processing_time_ms(opts) do
    with start when is_integer(start) <- Keyword.get(opts, :started_at),
         stop when is_integer(stop) <- Keyword.get(opts, :finished_at) do
      max(div(stop - start, 1_000), 0)
    else
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
