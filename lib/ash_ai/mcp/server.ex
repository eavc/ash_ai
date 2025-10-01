defmodule AshAi.Mcp.Server do
  @moduledoc """
  Implementation of the Model Context Protocol (MCP) RPC functionality.

  This module handles HTTP requests and responses according to the MCP specification,
  supporting both synchronous and streaming communication patterns.
  It also handles the core JSON-RPC message processing for the protocol.
  """

  require Logger
  require Macro

  @doc """
  Process an HTTP POST request containing JSON-RPC messages
  """
  # sobelow_skip ["XSS.SendResp"]
  def handle_post(conn, body, session_id, opts \\ []) do
    accept_header = Plug.Conn.get_req_header(conn, "accept")
    _accept_sse = Enum.any?(accept_header, &String.contains?(&1, "text/event-stream"))
    _accept_json = Enum.any?(accept_header, &String.contains?(&1, "application/json"))

    opts =
      [
        actor: Ash.PlugHelpers.get_actor(conn),
        tenant: Ash.PlugHelpers.get_tenant(conn),
        context: Ash.PlugHelpers.get_context(conn) || %{}
      ]
      |> Keyword.merge(opts)

    version = expected_protocol_version(conn, opts)

    case process_request(body, session_id, opts) do
      {:initialize_response, response, new_session_id} ->
        # Return the initialize response with a session ID header
        conn
        |> Plug.Conn.put_resp_header("mcp-protocol-version", version)
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.put_resp_header("mcp-session-id", new_session_id)
        |> Plug.Conn.send_resp(200, response)

      {:json_response, response, _session_id} ->
        # Regular JSON response
        conn
        |> Plug.Conn.put_resp_header("mcp-protocol-version", version)
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, response)

      {:no_response, _, _} ->
        # For notifications or other messages that don't require a response
        conn
        |> Plug.Conn.put_resp_header("mcp-protocol-version", version)
        |> Plug.Conn.send_resp(202, "")
    end
  end

  @doc """
  Process an HTTP GET request to open an SSE stream
  """
  def handle_get(conn, session_id) do
    accept_header = Plug.Conn.get_req_header(conn, "accept")

    if Enum.any?(accept_header, &String.contains?(&1, "text/event-stream")) do
      # Get the current host and path to create the post URL
      host = Plug.Conn.get_req_header(conn, "host") |> List.first()
      scheme = if conn.scheme == :https, do: "https", else: "http"
      path = conn.request_path
      post_url = "#{scheme}://#{host}#{path}"

      # Set up SSE stream
      conn
      |> Plug.Conn.put_resp_header(
        "mcp-protocol-version",
        expected_protocol_version(conn, conn.assigns[:router_opts] || [])
      )
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      # Send the post_url in an endpoint event according to MCP specification
      |> Plug.Conn.send_chunked(200)
      |> send_sse_event(
        "endpoint",
        Jason.encode!(%{
          "url" => post_url,
          "_meta" => %{
            "endpoint" => post_url,
            "sessionId" => session_id,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        })
      )
      |> Plug.Conn.halt()
    else
      # Client doesn't support SSE
      conn
      |> Plug.Conn.put_resp_header(
        "mcp-protocol-version",
        expected_protocol_version(conn, conn.assigns[:router_opts] || [])
      )
      |> Plug.Conn.send_resp(400, "Client must accept text/event-stream")
    end
  end

  @doc """
  Handle HTTP DELETE request for session termination
  """
  def handle_delete(conn, session_id) do
    if session_id do
      conn
      |> Plug.Conn.send_resp(200, "")
    else
      conn
      |> Plug.Conn.send_resp(400, "")
    end
  end

  @doc """
  Send an SSE event over the chunked connection
  """
  def send_sse_event(conn, event, data, id \\ nil) do
    chunks = [
      if(id, do: "id: #{id}\n", else: ""),
      "event: #{event}\n",
      "data: #{data}\n\n"
    ]

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  @doc """
  Get the MCP server version
  """
  def get_server_version(opts) do
    if opts[:mcp_server_version] do
      opts[:mcp_server_version]
    else
      if opts[:otp_app] do
        case :application.get_key(opts[:otp_app], :vsn) do
          {:ok, version} -> List.to_string(version)
          :undefined -> "0.1.0"
        end
      else
        "0.1.0"
      end
    end
  end

  @doc """
  Get the MCP server name
  """
  def get_server_name(opts) do
    if opts[:mcp_name] do
      opts[:mcp_name]
    else
      if opts[:otp_app] do
        "MCP Server"
      else
        "#{opts[:otp_app]} MCP Server"
      end
    end
  end

  defp process_request(request, session_id, opts) do
    case parse_json_rpc(request) do
      {:ok, message} when is_map(message) ->
        # Process a single message
        process_message(message, session_id, opts)

      {:ok, batch} when is_list(batch) ->
        # JSON-RPC batching removed per MCP 2025-06-18
        {:json_response,
         json_rpc_error_response(nil, -32_600, "Batch requests are not supported", %{
           "reason" => "json-rpc-batching-removed"
         }), session_id}

      {:error, error} ->
        # Handle parsing errors
        response =
          json_rpc_error_response(nil, -32_700, "Parse error", %{"details" => inspect(error)})

        {:json_response, response, session_id}
    end
  end

  @doc """
  Process a single JSON-RPC message
  """
  def process_message(message, session_id, opts) do
    case message do
      %{"method" => "initialize", "id" => id, "params" => _params} ->
        # Handle initialize request
        new_session_id = session_id || Ash.UUIDv7.generate()

        protocol_version_statement = Keyword.get(opts, :protocol_version_statement, "2025-06-18")

        # Return capabilities
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "serverInfo" => %{
              "name" => get_server_name(opts),
              "version" => get_server_version(opts)
            },
            "protocolVersion" => protocol_version_statement,
            "capabilities" => %{
              "tools" => %{
                "listChanged" => false
              }
            }
          }
        }

        {:initialize_response, Jason.encode!(response), new_session_id}

      %{"method" => "shutdown", "id" => id, "params" => _params} ->
        # Return success
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => nil
        }

        {:json_response, Jason.encode!(response), session_id}

      %{"method" => "$/cancelRequest", "params" => %{"id" => _request_id}} ->
        # TODO: Cancel request?
        {:no_response, nil, session_id}

      %{"method" => "tools/list", "id" => id} ->
        started_at = System.monotonic_time(:microsecond)

        items =
          opts
          |> tools()
          |> Enum.map(fn %{tool: tool_def, function: function} ->
            %{
              "name" => function.name,
              "title" => tool_def.title,
              "description" => function.description,
              "inputSchema" => function.parameters_schema,
              "defaultContentType" => tool_def.default_content_type || "application/json",
              "outputSchema" => tool_def.output_schema,
              "_meta" =>
                %{}
                |> put_if("category", tool_def.category)
                |> put_if("version", tool_def.version)
            }
          end)

        finished_at = System.monotonic_time(:microsecond)
        duration = max(finished_at - started_at, 0)

        :telemetry.execute(
          [:ash_ai, :mcp, :tools, :list],
          %{duration: duration},
          %{count: length(items), otp_app: opts[:otp_app]}
        )

        result = %{
          "tools" => items,
          "_meta" => %{
            "count" => length(items),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }

        response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
        {:json_response, Jason.encode!(response), session_id}

      %{"method" => "tools/call", "id" => id, "params" => params} ->
        tool_name = params["name"]
        tool_args = params["arguments"] || %{}

        tool_opts =
          opts
          |> Keyword.update(
            :context,
            %{mcp_session_id: session_id},
            &Map.put(&1, :mcp_session_id, session_id)
          )
          |> Keyword.put(:filter, fn tool -> tool.mcp == :tool end)

        tool_entry =
          tool_opts
          |> tools()
          |> Enum.find(&(&1.function.name == tool_name))

        case tool_entry do
          nil ->
            :telemetry.execute(
              [:ash_ai, :mcp, :tools, :call],
              %{duration: 0},
              %{status: :error, reason: :tool_not_found, tool: tool_name, otp_app: opts[:otp_app]}
            )

            response = %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{
                "code" => -32_602,
                "message" => "Tool not found: #{tool_name}"
              }
            }

            {:json_response, Jason.encode!(response), session_id}

          %{tool: tool_def, function: function_struct} ->
            started_at = System.monotonic_time(:microsecond)

            context =
              tool_opts
              |> Keyword.take([:actor, :tenant, :context])
              |> Map.new()
              |> Map.update(
                :context,
                %{otp_app: opts[:otp_app]},
                &Map.put(&1, :otp_app, opts[:otp_app])
              )

            function_struct.function.(tool_args, context)
            |> case do
              {:ok, result_text, _processed} ->
                finished_at = System.monotonic_time(:microsecond)
                duration = max(finished_at - started_at, 0)

                data =
                  case Jason.decode(result_text) do
                    {:ok, decoded} -> decoded
                    _ -> result_text
                  end

                public_base_url = resolve_public_base_url(tool_opts)

                resource_links =
                  resolve_resource_links(tool_def, tool_opts, data, public_base_url)

                meta_context = %{
                  data: data,
                  session_id: session_id,
                  request_id: id,
                  tool: tool_def,
                  arguments: tool_args,
                  router_opts: tool_opts,
                  public_base_url: public_base_url,
                  status: :ok,
                  raw_result: result_text
                }

                result_payload =
                  AshAi.Mcp.ResponseBuilder.tool_result(
                    content_type: tool_def.default_content_type || "application/json",
                    data: data,
                    schema: tool_def.output_schema,
                    resource_links: resource_links,
                    session_id: session_id,
                    request_id: id,
                    started_at: started_at,
                    finished_at: finished_at,
                    meta_builder: tool_meta_builder(tool_def, tool_opts),
                    meta_context: meta_context
                  )

                :telemetry.execute(
                  [:ash_ai, :mcp, :tools, :call],
                  %{duration: duration},
                  tool_call_metadata(tool_opts, tool_def, tool_name, :ok)
                )

                response = %{"jsonrpc" => "2.0", "id" => id, "result" => result_payload}
                {:json_response, Jason.encode!(response), session_id}

              {:error, error_text} ->
                finished_at = System.monotonic_time(:microsecond)
                duration = max(finished_at - started_at, 0)

                error_map =
                  case Jason.decode(error_text) do
                    {:ok, decoded} when is_map(decoded) -> decoded
                    _ -> %{"errors" => List.wrap(error_text)}
                  end

                meta_context = %{
                  data: error_map,
                  session_id: session_id,
                  request_id: id,
                  tool: tool_def,
                  arguments: tool_args,
                  router_opts: tool_opts,
                  public_base_url: resolve_public_base_url(tool_opts),
                  status: :error,
                  error: error_map
                }

                payload =
                  AshAi.Mcp.ResponseBuilder.tool_error(
                    error: error_map,
                    session_id: session_id,
                    request_id: id,
                    started_at: started_at,
                    finished_at: finished_at,
                    meta_builder: tool_meta_builder(tool_def, tool_opts),
                    meta_context: meta_context
                  )

                :telemetry.execute(
                  [:ash_ai, :mcp, :tools, :call],
                  %{duration: duration},
                  tool_call_metadata(
                    tool_opts,
                    tool_def,
                    tool_name,
                    :error,
                    :tool_execution_error
                  )
                )

                response = %{"jsonrpc" => "2.0", "id" => id, "result" => payload}
                {:json_response, Jason.encode!(response), session_id}
            end
        end

      %{"method" => method, "id" => id, "params" => _params} ->
        # Handle other requests with IDs (requiring responses)
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32_601,
            "message" => "Method not implemented: #{method}"
          }
        }

        {:json_response, Jason.encode!(response), session_id}

      %{"method" => _method} ->
        # Handle other notifications (no id)
        {:no_response, nil, session_id}

      other ->
        # Invalid message
        {:json_response,
         json_rpc_error_response(nil, -32_600, "Invalid Request Got: #{inspect(other)}"),
         session_id}
    end
  end

  defp tools(opts) do
    opts =
      if opts[:tools] == :ash_dev_tools do
        opts
        |> Keyword.put(:actions, [{AshAi.DevTools.Tools, :*}])
        |> Keyword.put(:tools, [
          :list_ash_resources,
          :list_generators,
          :get_usage_rules,
          :list_packages_with_rules
        ])
      else
        opts
      end

    base_opts =
      opts
      |> Keyword.take([:otp_app, :tools, :actor, :context, :tenant, :actions])
      |> Keyword.update(
        :context,
        %{otp_app: opts[:otp_app]},
        &Map.put(&1, :otp_app, opts[:otp_app])
      )

    defs = AshAi.exposed_tools(base_opts)
    funcs = AshAi.functions(base_opts)

    for tool_def <- defs, function <- funcs, function.name == to_string(tool_def.name) do
      %{tool: enrich_tool(tool_def), function: function}
    end
  end

  @doc """
  Parse the JSON-RPC request
  """
  def parse_json_rpc(request) when is_binary(request) do
    case Jason.decode(request) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} = error -> error
    end
  end

  def parse_json_rpc(%{"_json" => list}) when is_list(list), do: {:ok, list}
  def parse_json_rpc(%{_json: list}) when is_list(list), do: {:ok, list}

  def parse_json_rpc(request) when is_map(request) do
    {:ok, request}
  end

  @doc """
  Create a standard JSON-RPC error response
  """
  def json_rpc_error_response(id, code, message, meta \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if meta, do: Map.put(error, "_meta", meta), else: error

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => error
    })
  end

  defp expected_protocol_version(conn, opts) do
    case conn.assigns[:router_opts] do
      nil -> Keyword.get(opts, :protocol_version_statement, "2025-06-18")
      _ -> Keyword.get(opts, :protocol_version_statement, "2025-06-18")
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp enrich_tool(tool_def) do
    title =
      tool_def.name
      |> to_string()
      |> String.replace("_", " ")
      |> String.split(~r/\s+/)
      |> Enum.map_join(" ", &String.capitalize/1)

    category =
      tool_def.resource
      |> Module.split()
      |> List.last()

    output_schema =
      try do
        AshAi.JsonSchema.default_output_schema(%{
          action: tool_def.action,
          resource: tool_def.resource,
          load: tool_def.load
        })
      rescue
        _ -> %{"anyOf" => [%{"type" => "object"}]}
      end

    Map.merge(Map.from_struct(tool_def), %{
      title: title,
      default_content_type: Map.get(tool_def, :default_content_type) || "application/json",
      output_schema: output_schema,
      category: category,
      version: Map.get(tool_def, :version) || "1.0.0",
      resource_links: List.wrap(Map.get(tool_def, :resource_links) || []),
      resource_link_builder: Map.get(tool_def, :resource_link_builder),
      meta_builder: Map.get(tool_def, :meta_builder)
    })
  end

  defp resolve_public_base_url(opts) do
    opts
    |> Keyword.get(:public_base_url)
    |> case do
      nil -> System.get_env("MCP_PUBLIC_URL")
      value -> value
    end
    |> case do
      nil -> nil
      "" -> nil
      base -> String.trim_trailing(base, "/")
    end
  end

  defp resolve_resource_links(tool_def, opts, data, public_base_url) do
    explicit_links = tool_def.resource_links || []

    cond do
      Enum.any?(explicit_links) ->
        explicit_links

      builder = Map.get(tool_def, :resource_link_builder) ->
        invoke_resource_link_builder(builder, tool_def, data, opts, public_base_url)

      router_builder = Keyword.get(opts, :resource_link_builder) ->
        invoke_resource_link_builder(router_builder, tool_def, data, opts, public_base_url)

      public_base_url ->
        default_resource_links(public_base_url, tool_def)

      true ->
        []
    end
  end

  defp invoke_resource_link_builder(builder, tool_def, data, opts, public_base_url) do
    context = %{
      tool: tool_def,
      data: data,
      router_opts: opts,
      public_base_url: public_base_url
    }

    result =
      cond do
        is_function(builder, 1) -> builder.(context)
        is_function(builder, 2) -> builder.(tool_def, data)
        is_function(builder, 3) -> builder.(tool_def, data, context)
        true -> []
      end

    result =
      case result do
        {:ok, value} -> value
        {:ok, value, _extra} -> value
        other -> other
      end

    result
    |> case do
      nil -> []
      links when is_list(links) -> Enum.reject(links, &is_nil/1)
      link when is_map(link) -> [link]
      other -> List.wrap(other)
    end
  rescue
    exception ->
      Logger.warning("tool resource_link_builder failed: #{Exception.message(exception)}")
      []
  end

  defp default_resource_links(public_base_url, tool_def) when is_binary(public_base_url) do
    base =
      tool_def.resource
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.replace_suffix("_after_action", "")

    feed = public_base_url <> "/" <> base <> "-feed"

    [
      %{
        "href" => feed,
        "title" => "Collection",
        "type" => "application/vnd.api+json",
        "_meta" => %{"rel" => "collection"}
      },
      %{
        "href" => feed <> "/item",
        "title" => "Item",
        "type" => "application/vnd.api+json",
        "_meta" => %{"rel" => "item"}
      }
    ]
  end

  defp default_resource_links(_public_base_url, _tool_def), do: []

  defp tool_meta_builder(tool_def, opts) do
    Map.get(tool_def, :meta_builder) || Keyword.get(opts, :meta_builder)
  end

  defp tool_call_metadata(opts, tool_def, tool_name, status, reason \\ nil) do
    base = %{
      status: status,
      tool: tool_name,
      otp_app: Keyword.get(opts, :otp_app),
      resource: tool_def.resource,
      action: tool_def.action && tool_def.action.name
    }

    base
    |> maybe_put(:tenant, Keyword.get(opts, :tenant))
    |> maybe_put(:reason, reason)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
