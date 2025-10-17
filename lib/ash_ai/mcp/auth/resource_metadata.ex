defmodule AshAi.Mcp.Auth.ResourceMetadata do
  @moduledoc false

  import Plug.Conn

  alias AshAi.Mcp.Auth.Helpers

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
      opts[:public_base_url] || System.get_env("MCP_PUBLIC_URL") ||
        Helpers.default_public_base_url(conn)

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
        |> Helpers.normalize_scopes()

    authorization_servers =
      opts
      |> Map.get(:authorization_servers, System.get_env("MCP_AUTHORIZATION_SERVERS"))
      |> Helpers.derive_authorization_servers(opts)
      |> Helpers.normalize_list()

    documentation =
      opts
      |> Map.get(:resource_documentation) || System.get_env("MCP_RESOURCE_DOCUMENTATION")

    token_methods =
      opts
      |> Map.get(:token_endpoint_auth_methods_supported) ||
        System.get_env("MCP_TOKEN_ENDPOINT_AUTH_METHODS") ||
        ["client_secret_post", "client_secret_basic"]
        |> Helpers.normalize_list()

    # Default to RS256 when authorization_servers are present (OIDC/Auth0 convention)
    # Otherwise fall back to AshAuthentication's default algorithm
    signing_algorithms =
      opts
      |> Map.get(:resource_signing_algorithms_supported) ||
        Helpers.default_signing_algorithms(authorization_servers)
        |> Helpers.normalize_list()

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
end
