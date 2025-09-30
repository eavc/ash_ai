defmodule AshAi.Mcp.Auth.OidcJwksVerifierTest do
  use ExUnit.Case, async: true

  alias AshAi.Mcp.Auth.OidcJwksVerifier

  defmodule DummyActor do
  end

  defp now, do: System.system_time(:second)

  defp gen_rsa_jwk do
    JOSE.JWK.generate_key({:rsa, 2048})
  end

  defp jwk_public_map(jwk, kid) do
    {_fields, map} = JOSE.JWK.to_public(jwk) |> JOSE.JWK.to_map()
    Map.merge(map, %{"kid" => kid, "alg" => "RS256"})
  end

  defp sign_rs256(jwk, kid, claims) do
    jws = JOSE.JWT.sign(jwk, %{"alg" => "RS256", "kid" => kid}, claims)
    {_, token} = JOSE.JWS.compact(jws)
    token
  end

  test "verifies valid RS256 token with JWKS override" do
    issuer = "https://issuer.example.invalid"
    aud = "https://api.example.com/mcp"
    kid = "kid1"
    jwk = gen_rsa_jwk()

    token =
      sign_rs256(jwk, kid, %{
        "iss" => issuer,
        "aud" => aud,
        "exp" => now() + 300,
        "nbf" => now() - 10
      })

    jwks = %{"keys" => [jwk_public_map(jwk, kid)]}

    context = %{
      issuer: issuer,
      issuers: [issuer],
      resource_indicator: aud,
      actor_resource: DummyActor,
      jwks_overrides: %{String.trim_trailing(issuer, "/") => jwks},
      algorithms: ["RS256"]
    }

    assert {:ok, claims, DummyActor} = OidcJwksVerifier.verify(token, :unused, [], context)
    assert claims["iss"] == issuer
    assert aud in List.wrap(claims["aud"])
  end

  test "rejects invalid issuer" do
    issuer = "https://issuer.example.invalid"
    aud = "https://api.example.com/mcp"
    kid = "kid2"
    jwk = gen_rsa_jwk()
    # Wrong iss in token
    # note trailing slash
    bad_iss = "https://wrong.example.invalid/"
    token = sign_rs256(jwk, kid, %{"iss" => bad_iss, "aud" => aud, "exp" => now() + 300})
    jwks = %{"keys" => [jwk_public_map(jwk, kid)]}

    context = %{
      issuers: [issuer],
      resource_indicator: aud,
      actor_resource: DummyActor,
      jwks_overrides: %{String.trim_trailing(issuer, "/") => jwks},
      algorithms: ["RS256"]
    }

    assert :error = OidcJwksVerifier.verify(token, :unused, [], context)
  end

  test "rejects invalid audience" do
    issuer = "https://issuer.example.invalid"
    aud = "https://api.example.com/mcp"
    kid = "kid3"
    jwk = gen_rsa_jwk()

    token =
      sign_rs256(jwk, kid, %{"iss" => issuer, "aud" => "https://wrong", "exp" => now() + 300})

    jwks = %{"keys" => [jwk_public_map(jwk, kid)]}

    context = %{
      issuers: [issuer],
      resource_indicator: aud,
      actor_resource: DummyActor,
      jwks_overrides: %{String.trim_trailing(issuer, "/") => jwks},
      algorithms: ["RS256"]
    }

    assert :error = OidcJwksVerifier.verify(token, :unused, [], context)
  end

  test "rejects expired token with skew tolerance" do
    issuer = "https://issuer.example.invalid"
    aud = "https://api.example.com/mcp"
    kid = "kid4"
    jwk = gen_rsa_jwk()
    token = sign_rs256(jwk, kid, %{"iss" => issuer, "aud" => aud, "exp" => now() - 120})
    jwks = %{"keys" => [jwk_public_map(jwk, kid)]}

    context = %{
      issuers: [issuer],
      resource_indicator: aud,
      actor_resource: DummyActor,
      jwks_overrides: %{String.trim_trailing(issuer, "/") => jwks},
      algorithms: ["RS256"]
    }

    assert :error = OidcJwksVerifier.verify(token, :unused, [], context)
  end

  test "rejects unsupported algorithm" do
    issuer = "https://issuer.example.invalid"
    aud = "https://api.example.com/mcp"
    kid = "kid5"
    # Create HS256 token that should be rejected by allowed ["RS256"]
    jwk_hs = JOSE.JWK.from_oct("secretsecretsecretsecret")

    jws =
      JOSE.JWT.sign(jwk_hs, %{"alg" => "HS256", "kid" => kid}, %{
        "iss" => issuer,
        "aud" => aud,
        "exp" => now() + 300
      })

    {_, token} = JOSE.JWS.compact(jws)

    # JWKS contains no matching key since this is symmetric; still should fail earlier
    jwks = %{"keys" => []}

    context = %{
      issuers: [issuer],
      resource_indicator: aud,
      actor_resource: DummyActor,
      jwks_overrides: %{String.trim_trailing(issuer, "/") => jwks},
      algorithms: ["RS256"]
    }

    assert :error = OidcJwksVerifier.verify(token, :unused, [], context)
  end

  test "refreshes JWKS on signature failure" do
    issuer = "https://issuer.example.invalid"
    aud = "https://api.example.com/mcp"
    kid = "kid6"
    # Two RSA keys: old (wrong) and new (correct)
    old_jwk = gen_rsa_jwk()
    new_jwk = gen_rsa_jwk()
    token = sign_rs256(new_jwk, kid, %{"iss" => issuer, "aud" => aud, "exp" => now() + 300})

    # First override returns old key; then we update override and force refresh
    jwks_old = %{"keys" => [jwk_public_map(old_jwk, kid)]}
    jwks_new = %{"keys" => [jwk_public_map(new_jwk, kid)]}

    # Prime ETS cache with old JWKS for issuer
    :ets.new(:ash_ai_jwks_cache, [:named_table, :set, :public, read_concurrency: true])

    :ets.insert(
      :ash_ai_jwks_cache,
      {{:jwks, String.trim_trailing(issuer, "/")}, jwks_old, now() + 60}
    )

    # Context contains new JWKS to be fetched on refresh
    context = %{
      issuers: [issuer],
      resource_indicator: aud,
      actor_resource: DummyActor,
      jwks_overrides: %{String.trim_trailing(issuer, "/") => jwks_new},
      algorithms: ["RS256"]
    }

    assert {:ok, _claims, DummyActor} = OidcJwksVerifier.verify(token, :unused, [], context)
  end
end
