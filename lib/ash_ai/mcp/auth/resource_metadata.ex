defmodule AshAi.Mcp.Auth.ResourceMetadata do
  @moduledoc false

  import Plug.Conn

  alias AshAuthentication.Jwt

  @behaviour Plug

  @metadata_path "/.well-known/oauth-protected-resource"

  @impl Plug
  def init(opts), do: Enum.into(opts, %{})

  @impl Plug
  def call(%Plug.Conn{request_path: @metadata_path} = conn, init_opts) do
    router_opts = conn.assigns[:router_opts] || []
    router_opts_map = Enum.into(router_opts, %{})
    options = build_options(init_opts, router_opts_map, conn)
    body = Jason.encode!(metadata_payload(options))

    protocol_version =
      conn.assigns[:protocol_version] ||
        Map.get(router_opts_map, :protocol_version_statement) ||
        "2025-06-18"

    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header("mcp-protocol-version", protocol_version)
    |> resp(200, body)
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp build_options(init_opts, router_opts, conn) do
    opts = Map.merge(init_opts, router_opts)

    public_base_url =
      opts[:public_base_url] || System.get_env("MCP_PUBLIC_URL") || default_public_base_url(conn)

    resource_path = opts[:resource_path] || "/mcp"

    normalized_path =
      if String.starts_with?(resource_path, "/"), do: resource_path, else: "/" <> resource_path

    base = String.trim_trailing(public_base_url, "/")

    resource_indicator =
      opts[:resource_indicator] || base <> normalized_path

    required_scopes =
      opts
      |> Map.get(:required_scopes) || System.get_env("MCP_REQUIRED_SCOPES") ||
        []
        |> normalize_scopes()

    authorization_servers =
      opts
      |> Map.get(:authorization_servers, System.get_env("MCP_AUTHORIZATION_SERVERS"))
      |> derive_authorization_servers(opts)
      |> normalize_list()

    documentation =
      opts
      |> Map.get(:resource_documentation) || System.get_env("MCP_RESOURCE_DOCUMENTATION")

    token_methods =
      opts
      |> Map.get(:token_endpoint_auth_methods_supported) ||
        System.get_env("MCP_TOKEN_ENDPOINT_AUTH_METHODS") ||
        ["client_secret_post", "client_secret_basic"]
        |> normalize_list()

    # Default to RS256 when authorization_servers are present (OIDC/Auth0 convention)
    # Otherwise fall back to AshAuthentication's default algorithm
    signing_algorithms =
      opts
      |> Map.get(:resource_signing_algorithms_supported) ||
        default_signing_algorithms(authorization_servers)
        |> normalize_list()

    Map.merge(opts, %{
      public_base_url: public_base_url,
      resource_indicator: resource_indicator,
      required_scopes: required_scopes,
      authorization_servers: authorization_servers,
      resource_documentation: documentation,
      token_endpoint_auth_methods_supported: token_methods,
      resource_signing_algorithms_supported: signing_algorithms
    })
  end

  defp metadata_payload(opts) do
    %{
      "resource" => Map.fetch!(opts, :resource_indicator),
      "authorization_servers" => Map.get(opts, :authorization_servers, []),
      "scopes_supported" => Map.get(opts, :required_scopes, []),
      "bearer_methods_supported" => ["authorization_header"],
      "resource_documentation" => Map.get(opts, :resource_documentation),
      "resource_signing_algorithms_supported" =>
        Map.get(opts, :resource_signing_algorithms_supported, []),
      "token_endpoint_auth_methods_supported" =>
        Map.get(opts, :token_endpoint_auth_methods_supported, [])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp default_public_base_url(conn) do
    case get_req_header(conn, "host") do
      [host | _] ->
        scheme = if conn.scheme == :https, do: "https", else: "http"
        "#{scheme}://#{host}"

      _ ->
        raise ArgumentError,
              "Unable to determine MCP public URL. Configure :public_base_url or MCP_PUBLIC_URL"
    end
  end

  defp normalize_scopes(scopes) do
    scopes
    |> normalize_list_like()
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(values) do
    values
    |> normalize_list_like()
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list_like(value) do
    if is_binary(value) do
      value
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.trim/1)
    else
      value
      |> List.wrap()
      |> Enum.map(&to_string/1)
    end
  end

  defp default_signing_algorithms(authorization_servers) when is_list(authorization_servers) do
    if Enum.empty?(authorization_servers) do
      [Jwt.default_algorithm()]
    else
      ["RS256"]
    end
  end

  defp derive_authorization_servers(value, opts) do
    value
    |> normalize_authorization_value()
    |> case do
      [] -> authorization_servers_from_context(Map.get(opts, :verifier_context))
      list -> list
    end
  end

  defp normalize_authorization_value(nil), do: []

  defp normalize_authorization_value(value) do
    value
    |> normalize_list_like()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp authorization_servers_from_context(context) do
    context = mapify(context)

    explicit =
      (Map.get(context, :authorization_servers) ||
         Map.get(context, "authorization_servers") || [])
      |> normalize_authorization_value()

    issuers =
      (Map.get(context, :issuers) || Map.get(context, "issuers") || [])
      |> normalize_authorization_value()

    issuer =
      (Map.get(context, :issuer) || Map.get(context, "issuer"))
      |> case do
        nil -> []
        value -> [to_string(value)]
      end

    issuer_servers =
      (issuer ++ issuers)
      |> Enum.map(&issuer_to_authorization_server/1)
      |> Enum.reject(&is_nil/1)

    explicit
    |> Enum.concat(issuer_servers)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp issuer_to_authorization_server(nil), do: nil

  defp issuer_to_authorization_server(issuer) do
    issuer
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.trim_trailing(trimmed, "/") <> "/.well-known/oauth-authorization-server"
    end
  end

  defp mapify(value) when is_map(value), do: value
  defp mapify(value) when is_list(value), do: Map.new(value)
  defp mapify(_), do: %{}
end
