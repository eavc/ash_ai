defmodule AshAi.Mcp.ResponseBuilder do
  @moduledoc false

  require Logger

  @type timestamp :: String.t()

  @doc """
  Builds the MCP 2025-06-18 `tool_result` payload.
  """
  @spec tool_result(keyword()) :: map()
  def tool_result(opts) do
    {meta, builder_links} = meta_with_links(opts)

    resource_links =
      opts
      |> Keyword.get(:resource_links, [])
      |> merge_resource_links(builder_links)

    %{
      "type" => "tool_result",
      "content" => [content(opts)],
      "_meta" => meta
    }
    |> maybe_put_resource_links(resource_links)
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
      "_meta" => meta_only(opts)
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
      "_meta" => meta_only(opts)
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

  defp meta_only(opts) do
    opts
    |> meta_with_links()
    |> elem(0)
  end

  defp meta_with_links(opts) do
    base_meta = %{
      "sessionId" => Keyword.get(opts, :session_id),
      "requestId" => Keyword.get(opts, :request_id),
      "timestamp" => Keyword.get(opts, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601()),
      "processingTimeMs" => processing_time_ms(opts)
    }

    meta_builder = Keyword.get(opts, :meta_builder)
    meta_context = Keyword.get(opts, :meta_context, %{})

    {additional_meta, builder_links} =
      if is_function(meta_builder, 1) do
        invoke_meta_builder(meta_builder, opts, meta_context)
      else
        {%{}, []}
      end

    meta =
      base_meta
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
      |> Map.merge(additional_meta)

    {meta, builder_links}
  end

  defp invoke_meta_builder(builder, opts, extra_context) do
    context =
      %{
        data: Keyword.get(opts, :data),
        session_id: Keyword.get(opts, :session_id),
        request_id: Keyword.get(opts, :request_id)
      }
      |> Map.merge(extra_context || %{})

    builder
    |> apply_meta_builder(context)
    |> normalize_meta_builder_result()
  rescue
    exception ->
      Logger.warning("tool meta_builder failed: #{Exception.message(exception)}")
      {%{}, []}
  end

  defp apply_meta_builder(builder, context) do
    builder.(context)
  end

  defp normalize_meta_builder_result({:ok, meta}) when is_map(meta), do: {meta, []}

  defp normalize_meta_builder_result({:ok, meta, links}) do
    {meta || %{}, List.wrap(links || [])}
  end

  defp normalize_meta_builder_result(%{meta: meta} = result) when is_map(meta) do
    links =
      Map.get(result, :resource_links) || Map.get(result, "resource_links") ||
        Map.get(result, :resourceLinks)

    {meta, List.wrap(links || [])}
  end

  defp normalize_meta_builder_result(result) when is_map(result), do: {result, []}
  defp normalize_meta_builder_result(result) when is_list(result), do: {Map.new(result), []}
  defp normalize_meta_builder_result(_other), do: {%{}, []}

  defp merge_resource_links(existing, additional) do
    existing = List.wrap(existing)
    additional = List.wrap(additional)

    cond do
      existing == [] and additional == [] -> []
      additional == [] -> existing
      existing == [] -> additional
      true -> existing ++ additional
    end
  end

  defp maybe_put_resource_links(map, []), do: map
  defp maybe_put_resource_links(map, links), do: Map.put(map, "resourceLinks", links)

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
