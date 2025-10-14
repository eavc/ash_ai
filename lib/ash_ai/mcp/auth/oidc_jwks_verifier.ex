defmodule AshAi.Mcp.Auth.OidcJwksVerifier do
  @moduledoc """
  OIDC/JWKS-based JWT verification for OAuth Bearer tokens.

  This verifier fetches JWKS (JSON Web Key Set) from OpenID Connect providers
  and verifies JWT tokens using public keys. It supports multiple issuers,
  key rotation, and automatic JWKS caching.

  ## Usage

  Configure the verifier in your MCP pipeline:

      pipeline :mcp do
        plug AshAi.Mcp.Auth.OAuthBearerPlug,
          otp_app: :my_app,
          verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4,
          verifier_context: [
            issuer: "https://my-tenant.auth0.com",
            resource_indicator: "https://api.example.com/mcp",
            actor_resource: MyApp.Accounts.User
          ]
      end

  ## Context Options

  The verifier expects the following in the `context` parameter:

  * `:issuer` - Single issuer URL (e.g., "https://auth.example.com")
  * `:issuers` - List of allowed issuer URLs (alternative to `:issuer`)
  * `:resource_indicator` - Expected audience value (required)
  * `:actor_resource` - The Ash resource module for actor resolution (required)
  * `:algorithms` - List of allowed signing algorithms (default: `["RS256"]`)
  * `:clock_skew_seconds` - Clock skew tolerance in seconds (default: `30`)

  ## JWKS Caching

  JWKS are cached for 15 minutes by default, respecting Cache-Control headers
  from the issuer. On signature verification failure, the cache is refreshed
  once to handle key rotation.

  The cache is managed by a supervised GenServer (`AshAi.Mcp.Auth.JwksCache`)
  with a protected ETS table to prevent cache poisoning attacks.

  ## Examples

      # Single issuer
      verifier_context: [
        issuer: "https://my-tenant.auth0.com",
        resource_indicator: "https://api.example.com/mcp",
        actor_resource: MyApp.Accounts.User
      ]

      # Multiple issuers (for multi-tenant scenarios)
      verifier_context: [
        issuers: [
          "https://tenant1.auth0.com",
          "https://tenant2.auth0.com"
        ],
        resource_indicator: "https://api.example.com/mcp",
        actor_resource: MyApp.Accounts.User,
        algorithms: ["RS256", "RS384"]
      ]
  """

  require Logger

  alias AshAi.Mcp.Auth.JwksCache

  @doc """
  Verifies a JWT token using OIDC/JWKS.

  Returns `{:ok, claims, resource}` on success or `:error` on failure.

  The `resource` returned is the `actor_resource` from the context, which
  the plug uses for subject resolution.
  """
  @spec verify(String.t(), any(), keyword(), map() | keyword()) ::
          {:ok, map(), module()} | :error

  # Accept keyword list and convert to map
  def verify(token, target, opts, context) when is_list(context) do
    verify(token, target, opts, Map.new(context))
  end

  def verify(token, _target, _opts, context) when is_map(context) do
    context = normalize_context(context)

    with {:ok, header} <- decode_header(token),
         _ <- Logger.debug("JWT header: #{inspect(header)}"),
         {:ok, kid} <- extract_kid(header),
         {:ok, alg} <- extract_alg(header),
         :ok <- validate_algorithm(alg, context),
         {:ok, {issuer, jwks}} <- fetch_jwks_for_kid(context, kid),
         {:ok, jwk} <- find_key(jwks, kid) do
      case verify_signature_strict(token, jwk, context) do
        {:ok, claims} ->
          with :ok <- validate_issuer(claims, context),
               :ok <- validate_audience(claims, context),
               :ok <- validate_expiration(claims, context) do
            resource = Map.fetch!(context, :actor_resource)
            {:ok, claims, resource}
          else
            _ -> :error
          end

        {:error, _} ->
          Logger.debug(
            "Signature verification failed. Forcing JWKS refresh for #{issuer} kid=#{kid}"
          )

          JwksCache.force_refresh(issuer)
          refetch_and_verify(token, context, issuer, kid)
      end
    else
      {:error, reason} ->
        Logger.debug("Token verification failed: #{inspect(reason)}")
        :error

      :error ->
        :error
    end
  end

  defp normalize_context(context) when is_map(context) do
    # Normalize a known set of context keys without converting arbitrary strings to atoms
    fetch = fn map, key -> Map.get(map, key) || Map.get(map, to_string(key)) end

    issuers =
      cond do
        v = fetch.(context, :issuers) -> List.wrap(v)
        v = fetch.(context, :issuer) -> [v]
        true -> []
      end

    algorithms = fetch.(context, :algorithms) || ["RS256"]
    resource_indicator = fetch.(context, :resource_indicator)
    actor_resource = fetch.(context, :actor_resource)
    jwks_overrides = fetch.(context, :jwks_overrides) || %{}
    clock_skew_seconds = fetch.(context, :clock_skew_seconds) || 30
    workos_client_id = fetch.(context, :workos_client_id) || fetch_workos_client_id()

    enforce_resource_audience? =
      case fetch.(context, :enforce_resource_audience?) do
        nil ->
          # WorkOS AuthKit currently issues access tokens with aud=client_id while
          # RFC 8707 resource indicators are still rolling out. We default to
          # skipping audience enforcement for AuthKit issuers to avoid rejecting
          # valid tokens, but allow callers to opt back in when providers comply.
          not workos_issuer?(issuers)

        value ->
          truthy?(value)
      end

    %{
      issuers: issuers,
      algorithms: algorithms,
      resource_indicator: resource_indicator,
      actor_resource: actor_resource,
      jwks_overrides: jwks_overrides,
      clock_skew_seconds: clock_skew_seconds,
      workos_client_id: workos_client_id,
      enforce_resource_audience?: enforce_resource_audience?
    }
  end

  defp decode_header(token) do
    case String.split(token, ".") do
      [header_b64 | _] ->
        with {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
             {:ok, header} <- Jason.decode(header_json) do
          {:ok, header}
        else
          _ -> {:error, :invalid_token_format}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  rescue
    _ -> {:error, :invalid_token_format}
  end

  defp extract_kid(header) do
    case Map.get(header, "kid") do
      nil -> {:error, :missing_kid}
      kid when is_binary(kid) -> {:ok, kid}
      _ -> {:error, :invalid_kid}
    end
  end

  defp extract_alg(header) do
    case Map.get(header, "alg") do
      nil -> {:error, :missing_alg}
      alg when is_binary(alg) -> {:ok, alg}
      _ -> {:error, :invalid_alg}
    end
  end

  defp validate_algorithm(alg, %{algorithms: allowed}) do
    if alg in allowed do
      :ok
    else
      {:error, :unsupported_algorithm}
    end
  end

  defp fetch_jwks_for_kid(context, kid) do
    issuers = Map.get(context, :issuers, [])

    # First try the kid index for O(1) lookup
    case JwksCache.find_issuer_for_kid(kid) do
      {:ok, issuer} ->
        case JwksCache.get_jwks(issuer, context) do
          {:ok, jwks} -> {:ok, {issuer, jwks}}
          {:error, _} -> fallback_issuer_search(issuers, kid, context)
        end

      :error ->
        fallback_issuer_search(issuers, kid, context)
    end
  end

  defp fallback_issuer_search(issuers, kid, context) do
    issuers
    |> Enum.reduce_while({:error, :no_matching_jwks}, fn issuer, _acc ->
      case JwksCache.get_jwks(issuer, context) do
        {:ok, jwks} ->
          case find_key(jwks, kid) do
            {:ok, _jwk} -> {:halt, {:ok, {issuer, jwks}}}
            _ -> {:cont, {:error, :no_matching_jwks}}
          end

        {:error, _} ->
          {:cont, {:error, :no_matching_jwks}}
      end
    end)
  end

  defp find_key(%{"keys" => keys}, kid) when is_list(keys) do
    case Enum.find(keys, fn key -> Map.get(key, "kid") == kid end) do
      nil -> {:error, :key_not_found}
      jwk -> {:ok, jwk}
    end
  end

  defp find_key(_jwks, _kid), do: {:error, :invalid_jwks_format}

  defp verify_signature_strict(token, jwk, context) do
    jose_jwk = JOSE.JWK.from(jwk)
    allowed = Map.get(context, :algorithms, ["RS256"])

    case JOSE.JWT.verify_strict(jose_jwk, allowed, token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, stringify_keys(claims)}
      {false, _jwt, _jws} -> {:error, :signature_verification_failed}
    end
  rescue
    e ->
      Logger.debug("JWT verification exception: #{inspect(e)}")
      {:error, :verification_exception}
  end

  defp validate_issuer(claims, %{issuers: issuers}) do
    claim_iss = Map.get(claims, "iss") |> normalize_issuer()
    normalized = Enum.map(issuers, &normalize_issuer/1)

    if claim_iss in normalized do
      :ok
    else
      {:error, :invalid_issuer}
    end
  end

  defp validate_audience(_claims, %{enforce_resource_audience?: false}), do: :ok

  defp validate_audience(claims, context) do
    expected_aud = Map.get(context, :resource_indicator)
    claim_aud = claims |> Map.get("aud") |> List.wrap()

    if expected_aud in claim_aud do
      :ok
    else
      {:error, :invalid_audience}
    end
  end

  defp validate_expiration(claims, context) do
    now = System.system_time(:second)
    skew = Map.get(context, :clock_skew_seconds, 30)

    with :ok <- check_exp(claims, now, skew) do
      check_nbf(claims, now, skew)
    end
  end

  defp check_exp(claims, now, skew) do
    case Map.get(claims, "exp") do
      nil ->
        {:error, :missing_exp}

      exp when is_integer(exp) ->
        if exp > now - skew do
          :ok
        else
          {:error, :token_expired}
        end

      _ ->
        {:error, :invalid_exp}
    end
  end

  defp check_nbf(claims, now, skew) do
    case Map.get(claims, "nbf") do
      nil ->
        :ok

      nbf when is_integer(nbf) ->
        if nbf <= now + skew do
          :ok
        else
          {:error, :token_not_yet_valid}
        end

      _ ->
        {:error, :invalid_nbf}
    end
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

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_binary(value), do: String.downcase(value) not in ["", "false", "0"]
  defp truthy?(value) when is_integer(value), do: value != 0
  defp truthy?(value) when is_nil(value), do: false
  defp truthy?(_value), do: true

  defp workos_issuer?(issuers) when is_list(issuers) do
    Enum.any?(issuers, fn
      issuer when is_binary(issuer) ->
        issuer
        |> URI.parse()
        |> Map.get(:host)
        |> case do
          nil -> false
          host -> String.ends_with?(host, ".authkit.app")
        end

      _ ->
        false
    end)
  end

  defp workos_issuer?(_), do: false

  defp fetch_workos_client_id do
    System.get_env("WORKOS_MCP_CLIENT_ID") || System.get_env("WORKOS_CLIENT_ID")
  end

  defp refetch_and_verify(token, context, issuer, kid) do
    with {:ok, jwks} <- JwksCache.get_jwks(issuer, context),
         {:ok, jwk} <- find_key(jwks, kid),
         {:ok, claims} <- verify_signature_strict(token, jwk, context),
         :ok <- validate_issuer(claims, context),
         :ok <- validate_audience(claims, context),
         :ok <- validate_expiration(claims, context) do
      resource = Map.fetch!(context, :actor_resource)
      {:ok, claims, resource}
    else
      _ -> :error
    end
  end

  defp normalize_issuer(nil), do: nil
  defp normalize_issuer(iss) when is_binary(iss), do: String.trim_trailing(iss, "/")
end
