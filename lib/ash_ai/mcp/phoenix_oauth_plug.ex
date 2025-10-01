defmodule AshAi.Mcp.PhoenixOAuthPlug do
  @moduledoc """
  Convenience wrapper for configuring `AshAi.Mcp.Auth.OAuthBearerPlug` in Phoenix apps.

  The macro normalises runtime options, reads conventional environment variables, and allows
  projects to consolidate their MCP OAuth configuration in a single module:

      defmodule MyAppWeb.McpOAuthPlug do
        use AshAi.Mcp.PhoenixOAuthPlug,
          otp_app: :my_app,
          env: [
            public_base_url: "MCP_PUBLIC_URL",
            required_scopes: "MCP_REQUIRED_SCOPES"
          ],
          verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4,
          verifier_context: [
            actor_resource: MyApp.Accounts.User
          ]
      end

  Runtime options passed to the plug always override compile-time values. Environment variables
  can be customised via the `:env` option. Any value may use `{:env, var}`, `{:env!, var}` or
  the typed variants `{:env, var, :list}` / `{:env, var, :json}` which are resolved when the plug
  is initialised.
  """

  @default_env %{
    public_base_url: "MCP_PUBLIC_URL",
    resource_indicator: "MCP_RESOURCE_INDICATOR",
    required_scopes: {:list, "MCP_REQUIRED_SCOPES"},
    authorization_servers: {:list, "MCP_AUTHORIZATION_SERVERS"},
    www_authenticate_params: {:json, "MCP_WWW_AUTH_EXTRAS"},
    verifier_context: %{
      issuer: "MCP_ISSUER",
      resource_indicator: "MCP_RESOURCE_INDICATOR"
    }
  }

  defmacro __using__(opts \\ []) do
    quote bind_quoted: [opts: opts] do
      @behaviour Plug

      @ash_ai_oauth_opts AshAi.Mcp.PhoenixOAuthPlug.normalize_compile_opts(opts)

      @impl Plug
      def init(runtime_opts) do
        runtime_opts
        |> AshAi.Mcp.PhoenixOAuthPlug.prepare_options(@ash_ai_oauth_opts)
        |> AshAi.Mcp.Auth.OAuthBearerPlug.init()
      end

      @impl Plug
      def call(conn, opts) do
        AshAi.Mcp.Auth.OAuthBearerPlug.call(conn, opts)
      end
    end
  end

  @doc false
  def normalize_compile_opts(opts) when is_map(opts), do: Map.to_list(opts)
  def normalize_compile_opts(opts) when is_list(opts), do: opts
  def normalize_compile_opts(opts), do: List.wrap(opts)

  @doc false
  def prepare_options(runtime_opts, compile_opts) do
    compile_opts = normalize_compile_opts(compile_opts)
    runtime_opts = normalize_compile_opts(runtime_opts)

    # Merge compile-time and runtime options
    merged =
      compile_opts
      |> Keyword.merge(runtime_opts, fn _key, left, right -> merge_nested(left, right) end)

    # Extract and normalize env configuration
    {env_config, base_opts} = Keyword.pop(merged, :env, %{})

    env_config =
      @default_env
      |> deep_merge_env(mapify_env(env_config))

    # Resolve environment variables into options
    {opts_from_env, verifier_ctx_from_env} = resolve_env_config(env_config)

    # Merge: base_opts override env-resolved values
    base_opts
    |> merge_env_opts(opts_from_env)
    |> merge_verifier_context(verifier_ctx_from_env)
    |> resolve_option_placeholders()
  end

  # Resolve env configuration, returning {root_opts, verifier_context_opts}
  defp resolve_env_config(env_config) do
    root_opts =
      []
      |> maybe_put_from_env(:public_base_url, env_config[:public_base_url], & &1)
      |> maybe_put_from_env(:resource_indicator, env_config[:resource_indicator], & &1)
      |> maybe_put_from_env(:required_scopes, env_config[:required_scopes], &parse_scopes/1)
      |> maybe_put_from_env(
        :authorization_servers,
        env_config[:authorization_servers],
        &parse_list/1
      )
      |> maybe_put_from_env(
        :www_authenticate_params,
        env_config[:www_authenticate_params],
        &decode_www_params/1
      )

    verifier_ctx_opts =
      env_config
      |> Map.get(:verifier_context, %{})
      |> mapify_env()
      |> Enum.reduce([], fn {key, instruction}, acc ->
        case resolve_env_instruction(instruction) do
          {:ok, value} -> Keyword.put(acc, key, value)
          :error -> acc
        end
      end)

    {root_opts, verifier_ctx_opts}
  end

  # Merge env-resolved opts into base opts (base opts take precedence)
  defp merge_env_opts(base_opts, env_opts) do
    Keyword.merge(env_opts, base_opts)
  end

  # Merge verifier_context from env into existing verifier_context
  defp merge_verifier_context(opts, env_context) do
    existing_context =
      opts
      |> Keyword.get(:verifier_context, [])
      |> to_keyword()

    merged_context = Keyword.merge(env_context, existing_context)

    Keyword.put(opts, :verifier_context, merged_context)
  end

  # Helper for adding env-resolved values (only if not already present)
  defp maybe_put_from_env(opts, key, instruction, transform) do
    case resolve_env_instruction(instruction) do
      {:ok, value} ->
        processed = transform.(value)

        if present?(processed) do
          Keyword.put(opts, key, processed)
        else
          opts
        end

      :error ->
        opts
    end
  end

  defp merge_nested(left, right) when is_list(left) and is_list(right) do
    if Keyword.keyword?(left) and Keyword.keyword?(right) do
      Keyword.merge(left, right, fn _key, l, r -> merge_nested(l, r) end)
    else
      right
    end
  end

  defp merge_nested(_left, right), do: right

  defp resolve_option_placeholders(opts) do
    Enum.map(opts, fn
      {key, value} -> {key, resolve_placeholders(value)}
    end)
  end

  defp resolve_env_instruction(nil), do: :error

  defp resolve_env_instruction({:env, var}), do: fetch_env_value(var, :string, false)
  defp resolve_env_instruction({:env!, var}), do: fetch_env_value(var, :string, true)
  defp resolve_env_instruction({:env, var, type}), do: fetch_env_value(var, type, false)
  defp resolve_env_instruction({:env!, var, type}), do: fetch_env_value(var, type, true)

  defp resolve_env_instruction({type, var}) when type in [:string, :list, :json],
    do: fetch_env_value(var, type, false)

  defp resolve_env_instruction(var) when is_binary(var), do: fetch_env_value(var, :string, false)
  defp resolve_env_instruction(_), do: :error

  defp fetch_env_value(var, type, required?) do
    case System.get_env(var) do
      nil ->
        if required? do
          raise ArgumentError,
                "Environment variable #{var} is required for MCP OAuth configuration"
        else
          :error
        end

      value ->
        {:ok, cast_env(value, type)}
    end
  end

  defp cast_env(value, :string), do: value
  defp cast_env(value, :list), do: parse_list(value)
  defp cast_env(value, :json), do: decode_www_params(value)
  defp cast_env(value, _type), do: value

  defp resolve_placeholders({:env, var}), do: System.get_env(var)
  defp resolve_placeholders({:env!, var}), do: System.fetch_env!(var)
  defp resolve_placeholders({:env, var, :list}), do: parse_list(System.get_env(var) || "")

  defp resolve_placeholders({:env!, var, :list}) do
    System.fetch_env!(var) |> parse_list()
  end

  defp resolve_placeholders({:env, var, :json}), do: decode_www_params(System.get_env(var))

  defp resolve_placeholders({:env!, var, :json}) do
    System.fetch_env!(var) |> decode_www_params()
  end

  defp resolve_placeholders({:env, var, _type}), do: System.get_env(var)
  defp resolve_placeholders({:env!, var, _type}), do: System.fetch_env!(var)

  defp resolve_placeholders(list) when is_list(list) do
    if Keyword.keyword?(list) do
      Enum.map(list, fn {key, value} -> {key, resolve_placeholders(value)} end)
    else
      Enum.map(list, &resolve_placeholders/1)
    end
  end

  defp resolve_placeholders(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {key, resolve_placeholders(value)} end)
    |> Map.new()
  end

  defp resolve_placeholders(value), do: value

  defp parse_scopes(value) do
    value
    |> parse_list()
    |> Enum.uniq()
  end

  defp parse_list(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp parse_list(value), do: List.wrap(value) |> Enum.map(&to_string/1)

  defp decode_www_params(nil), do: nil
  defp decode_www_params(%{} = value), do: value
  defp decode_www_params(list) when is_list(list), do: list

  defp decode_www_params(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      case Jason.decode(trimmed) do
        {:ok, decoded} -> decoded
        _ -> parse_www_pairs(trimmed)
      end
    end
  end

  defp decode_www_params(value), do: value

  defp parse_www_pairs(value) do
    value
    |> String.split([","], trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, val] -> {String.trim(key), val |> String.trim() |> String.trim("\"")}
        [key] -> {String.trim(key), true}
      end
    end)
  end

  defp to_keyword(value) when is_list(value) do
    if Keyword.keyword?(value), do: value, else: List.wrap(value)
  end

  defp to_keyword(value) when is_map(value), do: Map.to_list(value)
  defp to_keyword(nil), do: []
  defp to_keyword(value), do: List.wrap(value)

  defp mapify_env(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {k, mapify_env(v)} end)
    |> Map.new()
  end

  defp mapify_env(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {k, v} -> {k, mapify_env(v)} end)
      |> Map.new()
    else
      value
    end
  end

  defp mapify_env(value), do: value

  defp deep_merge_env(left, right) do
    Map.merge(left, right, fn _key, l, r ->
      cond do
        is_map(l) and is_map(r) ->
          deep_merge_env(l, r)

        is_map(l) and is_list(r) ->
          if Keyword.keyword?(r), do: deep_merge_env(l, mapify_env(r)), else: r

        true ->
          r
      end
    end)
  end

  defp present?(value) do
    case value do
      nil -> false
      "" -> false
      [] -> false
      %{} = map -> map != %{}
      _ -> true
    end
  end
end
