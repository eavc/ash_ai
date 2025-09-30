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

  ## JWKS Caching

  JWKS are cached for 15 minutes by default, respecting Cache-Control headers
  from the issuer. On signature verification failure, the cache is refreshed
  once to handle key rotation.

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

  @default_cache_ttl_seconds 900
  @jwks_cache_table :ash_ai_jwks_cache

  @doc """
  Verifies a JWT token using OIDC/JWKS.

  Returns `{:ok, claims, resource}` on success or `:error` on failure.

  The `resource` returned is the `actor_resource` from the context, which
  the plug uses for subject resolution.
  """
  @spec verify(String.t(), any(), keyword(), map()) ::
          {:ok, map(), module()} | :error
  def verify(token, _target, _opts, context) when is_map(context) do
    context = normalize_context(context)

    with {:ok, header} <- decode_header(token),
         {:ok, kid} <- extract_kid(header),
         {:ok, alg} <- extract_alg(header),
         :ok <- validate_algorithm(alg, context),
         {:ok, {issuer, jwks}} <- fetch_jwks_for_kid(context, kid),
         {:ok, jwk} <- find_key(jwks, kid) do
      case verify_signature_strict(token, jwk, context) do
        {:ok, claims} ->
          with :ok <- validate_issuer(claims, context),
               :ok <- validate_audience(claims, context),
               :ok <- validate_expiration(claims) do
            resource = Map.fetch!(context, :actor_resource)
            {:ok, claims, resource}
          else
            _ -> :error
          end

        {:error, _} ->
          Logger.debug(
            "Signature verification failed. Forcing JWKS refresh for #{issuer} kid=#{kid}"
          )

          force_refresh_jwks(issuer)
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

    %{
      issuers: issuers,
      algorithms: algorithms,
      resource_indicator: resource_indicator,
      actor_resource: actor_resource,
      jwks_overrides: jwks_overrides
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

    issuers
    |> Enum.reduce_while({:error, :no_matching_jwks}, fn issuer, _acc ->
      case get_jwks_for_issuer(issuer, context) do
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

  defp get_jwks_for_issuer(issuer, context) do
    cache_key = {:jwks, issuer}

    case get_from_cache(cache_key) do
      {:ok, jwks} ->
        {:ok, jwks}

      :error ->
        case fetch_jwks_from_url(issuer, context) do
          {:ok, jwks, ttl} ->
            put_in_cache(cache_key, jwks, ttl)
            {:ok, jwks}

          {:error, _} = error ->
            error
        end
    end
  end

  defp fetch_jwks_from_url(issuer, context) do
    issuer = String.trim_trailing(issuer, "/")
    jwks_url = "#{issuer}/.well-known/jwks.json"

    # Allow test overrides without network
    overrides = Map.get(context, :jwks_overrides, %{})

    if jwks = Map.get(overrides, issuer) do
      {:ok, jwks, @default_cache_ttl_seconds}
    else
      case Req.get(url: jwks_url) do
        {:ok, %Req.Response{status: 200, body: body, headers: headers}} when is_map(body) ->
          ttl = parse_cache_ttl(headers)
          {:ok, body, ttl}

        {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
          case Jason.decode(body) do
            {:ok, map} ->
              ttl = parse_cache_ttl(headers)
              {:ok, map, ttl}

            _ ->
              Logger.warning("JWKS response not JSON from #{jwks_url}")
              {:error, :jwks_fetch_failed}
          end

        {:ok, %Req.Response{status: status}} ->
          Logger.warning("Failed to fetch JWKS from #{jwks_url}: HTTP #{status}")
          {:error, :jwks_fetch_failed}

        {:error, reason} ->
          Logger.warning("Failed to fetch JWKS from #{jwks_url}: #{inspect(reason)}")
          {:error, :jwks_fetch_failed}
      end
    end
  end

  defp parse_cache_ttl(headers) do
    headers
    |> Enum.find(fn {name, _value} -> String.downcase(name) == "cache-control" end)
    |> case do
      {_name, value} ->
        case Regex.run(~r/max-age=(\d+)/i, value) do
          [_, seconds] -> String.to_integer(seconds)
          _ -> @default_cache_ttl_seconds
        end

      nil ->
        @default_cache_ttl_seconds
    end
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

  defp validate_audience(claims, context) do
    expected_aud = Map.get(context, :resource_indicator)
    claim_aud = claims |> Map.get("aud") |> List.wrap()

    if expected_aud in claim_aud do
      :ok
    else
      {:error, :invalid_audience}
    end
  end

  defp validate_expiration(claims) do
    now = System.system_time(:second)
    skew = 60

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

  # Simple in-memory cache using ETS
  defp ensure_cache_table do
    case :ets.whereis(@jwks_cache_table) do
      :undefined ->
        :ets.new(@jwks_cache_table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp get_from_cache(key) do
    ensure_cache_table()

    case :ets.lookup(@jwks_cache_table, key) do
      [{^key, value, expires_at}] ->
        if System.system_time(:second) < expires_at do
          {:ok, value}
        else
          :ets.delete(@jwks_cache_table, key)
          :error
        end

      [] ->
        :error
    end
  end

  defp put_in_cache(key, value, ttl_seconds) do
    ensure_cache_table()
    expires_at = System.system_time(:second) + ttl_seconds
    :ets.insert(@jwks_cache_table, {key, value, expires_at})
    :ok
  end

  defp force_refresh_jwks(issuer) do
    ensure_cache_table()
    :ets.delete(@jwks_cache_table, {:jwks, issuer})
    :ok
  end

  defp refetch_and_verify(token, context, issuer, kid) do
    with {:ok, jwks, _ttl} <- fetch_jwks_from_url(issuer, context),
         {:ok, jwk} <- find_key(jwks, kid),
         {:ok, claims} <- verify_signature_strict(token, jwk, context),
         :ok <- validate_issuer(claims, context),
         :ok <- validate_audience(claims, context),
         :ok <- validate_expiration(claims) do
      resource = Map.fetch!(context, :actor_resource)
      {:ok, claims, resource}
    else
      _ -> :error
    end
  end

  defp normalize_issuer(nil), do: nil
  defp normalize_issuer(iss) when is_binary(iss), do: String.trim_trailing(iss, "/")
end
