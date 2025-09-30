defmodule AshAi.Mcp.Auth.OAuthBearerPlug do
  @moduledoc """
  IdP-agnostic OAuth 2.1 Bearer token verification plug for MCP servers.

  This plug validates OAuth bearer tokens and assigns the authenticated actor and tenant
  to the connection. It is compatible with any OAuth/OIDC provider through custom verifiers
  and subject resolvers.

  ## Configuration

  The plug accepts the following options (can be set in router options or plug init):

  * `:otp_app` or `:verify_target` - Required. The OTP application or verification target
  * `:verifier` - Token verification function (defaults to `AshAuthentication.Jwt.verify/4`)
  * `:verifier_context` - Context map passed to the verifier
  * `:verifier_opts` - Options list passed to the verifier
  * `:subject_resolver` - Subject-to-actor resolution function
  * `:subject_resolver_opts` - Options passed to subject resolver
  * `:public_base_url` - Base URL for resource indicator (or `MCP_PUBLIC_URL` env var)
  * `:resource_path` - Resource path (default: `/mcp`)
  * `:resource_indicator` - Explicit resource indicator (overrides derived value)
  * `:required_scopes` - List of required OAuth scopes (or `MCP_REQUIRED_SCOPES` env var)
  * `:oauth_required?` or `:required?` - Whether OAuth is mandatory (default: true)

  ## Examples

  ### Using with Auth0/OIDC and JWKS verification

      pipeline :mcp do
        plug AshAi.Mcp.Auth.OAuthBearerPlug,
          otp_app: :my_app,
          verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4,
          verifier_context: [
            issuer: "https://my-tenant.auth0.com",
            resource_indicator: "https://api.example.com/mcp",
            actor_resource: MyApp.Accounts.User
          ],
          public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
          required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
          required?: true
      end

  ### Using default AshAuthentication JWT verification

      pipeline :mcp do
        plug AshAi.Mcp.Auth.OAuthBearerPlug,
          otp_app: :my_app,
          public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
          resource_path: "/mcp",
          required_scopes: ["mcp:access"],
          required?: true
      end

  ## Custom Verifiers

  Verifiers must implement the signature:

      @spec verify(token :: String.t(), target :: atom(), opts :: keyword(), context :: map()) ::
        {:ok, claims :: map(), resource :: module()} | :error

  The verifier is responsible for:
  - Validating token signature and expiration
  - Returning decoded claims as a map
  - Returning the actor resource module

  Subject resolution (mapping `sub` to an actor) remains in the plug.

  ## Error Responses

  The plug returns JSON-RPC errors with enhanced WWW-Authenticate headers:

  * `401` with `invalid_token` - Missing, malformed, or invalid bearer token
  * `401` with `invalid_scope` - Token audience doesn't match resource indicator
  * `403` with `insufficient_scope` - Token missing required scopes

  WWW-Authenticate headers include:
  - `error` and `error_description` (RFC 6750)
  - `resource` - The resource indicator (extension parameter)
  - `error_uri` - Discovery endpoint (when available)
  - `scope` and `missing` - For insufficient scope errors
  """

  alias AshAi.Mcp.Auth.Scope
  alias AshAi.Mcp.Server
  alias AshAuthentication

  import Plug.Conn

  @behaviour Plug

  @metadata_path "/.well-known/oauth-protected-resource"

  @impl Plug
  def init(opts) do
    opts
    |> Keyword.put_new(:required?, true)
    |> Enum.into(%{})
  end

  def call(%Plug.Conn{assigns: %{oauth_claims: _}} = conn, _opts), do: conn

  @impl Plug
  def call(%Plug.Conn{request_path: @metadata_path} = conn, _opts), do: conn

  def call(conn, init_opts) do
    router_opts = conn.assigns[:router_opts] || []
    options = build_options(init_opts, router_opts, conn)

    with {:ok, token} <- fetch_bearer_token(conn, options),
         {:ok, claims, resource} <- verify_token(token, options),
         :ok <- validate_resource_indicator(claims, options),
         :ok <- validate_scopes(claims, options),
         {:ok, actor} <- resolve_actor(claims, resource, options) do
      conn
      |> maybe_put_tenant(claims)
      |> put_oauth_context(claims)
      |> Ash.PlugHelpers.set_actor(actor)
      |> assign(:oauth_claims, claims)
    else
      :skip ->
        conn

      {:error, status, error_code, reason, description, attrs} ->
        respond_with_error(conn, options, status, error_code, reason, description, attrs)
    end
  end

  defp build_options(init_opts, router_opts, conn) do
    router_opts = Enum.into(router_opts, %{})

    opts = Map.merge(init_opts, router_opts)

    required? = Map.get(opts, :oauth_required?, Map.get(opts, :required?, true))
    required? = if required? && !Map.has_key?(opts, :public_base_url), do: false, else: required?

    public_base_url =
      opts[:public_base_url] || System.get_env("MCP_PUBLIC_URL") || default_public_base_url(conn)

    resource_path = opts[:resource_path] || "/mcp"

    required_scopes =
      opts
      |> Map.get(:required_scopes) || System.get_env("MCP_REQUIRED_SCOPES") ||
        []
        |> normalize_scopes()

    verifier = opts[:verifier] || (&AshAuthentication.Jwt.verify/4)
    subject_resolver = opts[:subject_resolver] || (&default_subject_resolver/3)

    otp_app = opts[:otp_app]
    verify_target = opts[:verify_target] || otp_app

    verify_target ||
      raise ArgumentError, "OAuthBearerPlug requires :otp_app or :verify_target to be configured"

    normalized_path =
      if String.starts_with?(resource_path, "/"), do: resource_path, else: "/" <> resource_path

    base = String.trim_trailing(public_base_url, "/")

    resource_indicator =
      opts[:resource_indicator] || base <> normalized_path

    Map.merge(opts, %{
      required?: required?,
      public_base_url: public_base_url,
      resource_path: normalized_path,
      resource_indicator: resource_indicator,
      required_scopes: required_scopes,
      verifier: verifier,
      subject_resolver: subject_resolver,
      verify_target: verify_target
    })
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
    |> normalize_scope_source()
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_scope_source(scopes) do
    if is_binary(scopes) do
      scopes
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.trim/1)
    else
      scopes
      |> List.wrap()
      |> Enum.map(&to_string/1)
    end
  end

  defp fetch_bearer_token(conn, %{required?: required?}) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        {:ok, token}

      ["bearer " <> token | _] ->
        {:ok, token}

      [_ | _] ->
        {:error, 401, "invalid_token", "invalid_authorization_header",
         "Authorization header must use Bearer scheme", []}

      [] ->
        if required? do
          {:error, 401, "invalid_token", "missing_authorization", "Bearer access token required",
           []}
        else
          :skip
        end
    end
  end

  defp verify_token(token, %{verifier: verifier, verify_target: target} = opts) do
    context = Map.get(opts, :verifier_context, %{})
    verify_opts = Map.get(opts, :verifier_opts, [])

    case verifier.(token, target, verify_opts, context) do
      {:ok, claims, resource} ->
        {:ok, stringify_keys(claims), resource}

      :error ->
        {:error, 401, "invalid_token", "token_validation_failed",
         "Bearer token could not be verified", []}
    end
  end

  defp validate_resource_indicator(claims, %{resource_indicator: indicator}) do
    audiences =
      claims
      |> Map.get("aud")
      |> List.wrap()
      |> Enum.map(&to_string/1)

    if indicator in audiences do
      :ok
    else
      {:error, 401, "invalid_scope", "invalid_resource_indicator",
       "Token audience does not match required resource indicator", []}
    end
  end

  defp validate_scopes(_claims, %{required_scopes: []}), do: :ok

  defp validate_scopes(claims, %{required_scopes: required}) do
    granted = Scope.scopes_from_claims(claims)

    case Scope.missing_scopes(required, granted) do
      [] ->
        :ok

      missing ->
        {:error, 403, "insufficient_scope", "insufficient_scope",
         "Bearer token missing required scopes",
         [{"scope", Enum.join(required, " ")}, {"missing", Enum.join(missing, " ")}]}
    end
  end

  defp resolve_actor(claims, resource, %{subject_resolver: resolver} = opts) do
    case claims["sub"] do
      nil -> {:error, 401, "invalid_token", "missing_subject", "Token missing subject", []}
      subject -> resolver.(subject, resource, resolver_opts(opts, claims))
    end
  end

  defp resolver_opts(opts, claims) do
    case Map.get(claims, "tenant") do
      nil -> Map.get(opts, :subject_resolver_opts, [])
      tenant -> Keyword.put(Map.get(opts, :subject_resolver_opts, []), :tenant, tenant)
    end
  end

  defp default_subject_resolver(subject, resource, opts) do
    case AshAuthentication.subject_to_user(subject, resource, opts) do
      {:ok, actor} -> {:ok, actor}
      _ -> {:error, 401, "invalid_token", "unknown_subject", "Unable to resolve subject", []}
    end
  end

  defp maybe_put_tenant(conn, claims) do
    case Map.get(claims, "tenant") do
      nil -> conn
      tenant -> Ash.PlugHelpers.set_tenant(conn, tenant)
    end
  end

  defp put_oauth_context(conn, claims) do
    current = Ash.PlugHelpers.get_context(conn) || %{}
    Ash.PlugHelpers.set_context(conn, Map.put(current, :oauth_claims, claims))
  end

  defp stringify_keys(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      key = to_string(key)

      value =
        cond do
          is_map(value) -> stringify_keys(value)
          is_list(value) -> Enum.map(value, &stringify_keys/1)
          true -> value
        end

      {key, value}
    end
  end

  defp stringify_keys(value), do: value

  defp respond_with_error(conn, options, status, error_code, reason, description, attrs) do
    data = %{"reason" => reason}
    body = Server.json_rpc_error_response(nil, -32_600, description, data)

    authenticate_header = build_www_authenticate(error_code, description, attrs, options)

    protocol_version =
      conn.assigns[:protocol_version] ||
        (conn.assigns[:router_opts] || [])[:protocol_version_statement] ||
        "2025-06-18"

    conn
    |> put_resp_header("mcp-protocol-version", protocol_version)
    |> put_resp_header("www-authenticate", authenticate_header)
    |> put_resp_header("content-type", "application/json")
    |> resp(status, body)
    |> halt()
  end

  defp build_www_authenticate(error, description, attrs, options) do
    base = [error: error, error_description: description]

    # Add resource indicator if available
    resource_attrs =
      case Map.get(options, :resource_indicator) do
        nil -> []
        resource -> [{"resource", resource}]
      end

    # Add error_uri pointing to discovery endpoint if we have public_base_url
    error_uri_attrs =
      case Map.get(options, :public_base_url) do
        nil ->
          []

        base_url ->
          uri = String.trim_trailing(base_url, "/") <> @metadata_path
          [{"error_uri", uri}]
      end

    params =
      attrs
      |> Enum.map(fn
        {key, value} when is_atom(key) ->
          {Atom.to_string(key), value}

        other ->
          other
      end)
      |> Enum.concat(resource_attrs)
      |> Enum.concat(error_uri_attrs)
      |> Enum.concat(base)

    bearer_values =
      Enum.map_join(params, ", ", fn {key, value} ->
        value = if is_binary(value), do: value, else: to_string(value)
        ~s(#{key}="#{value}")
      end)

    "Bearer #{bearer_values}"
  end
end
