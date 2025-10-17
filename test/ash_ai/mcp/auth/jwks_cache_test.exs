defmodule AshAi.Mcp.Auth.JwksCacheTest do
  use ExUnit.Case, async: false

  alias AshAi.Mcp.Auth.JwksCache

  setup do
    JwksCache.clear_cache()
    :ok
  end

  describe "task crash handling" do
    test "replies with error when JWKS fetch task crashes" do
      issuer = "https://crash-test.example.invalid"

      # Create a context that will cause the fetch to crash
      context = %{
        jwks_overrides: %{
          issuer => :this_will_crash_when_accessed
        }
      }

      # The get_jwks call should return an error, not hang
      assert {:error, :jwks_fetch_failed} = JwksCache.get_jwks(issuer, context)
    end

    test "cleans up pending_fetches after task crash" do
      issuer = "https://crash-cleanup.example.invalid"

      context = %{
        jwks_overrides: %{
          issuer => :crash
        }
      }

      # First request crashes
      assert {:error, :jwks_fetch_failed} = JwksCache.get_jwks(issuer, context)

      # Subsequent request with valid data should work (not stuck behind crashed task)
      valid_jwks = %{"keys" => [%{"kid" => "key1", "kty" => "RSA"}]}

      valid_context = %{
        jwks_overrides: %{
          issuer => valid_jwks
        }
      }

      assert {:ok, ^valid_jwks} = JwksCache.get_jwks(issuer, valid_context)
    end

    test "concurrent requests to same issuer with crash are all notified" do
      issuer = "https://concurrent-crash.example.invalid"

      context = %{
        jwks_overrides: %{
          issuer => :crash
        }
      }

      # Start multiple concurrent requests
      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            JwksCache.get_jwks(issuer, context)
          end)
        end

      # All should receive the error, none should hang
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &match?({:error, :jwks_fetch_failed}, &1))
    end
  end

  describe "kid-to-issuer index" do
    test "finds issuer for kid after successful JWKS fetch" do
      issuer = "https://index-test.example.invalid"
      kid = "test-key-id"

      jwks = %{
        "keys" => [
          %{"kid" => kid, "kty" => "RSA", "n" => "...", "e" => "AQAB"}
        ]
      }

      context = %{jwks_overrides: %{issuer => jwks}}

      # Fetch JWKS to populate cache and index
      assert {:ok, _} = JwksCache.get_jwks(issuer, context)

      # Index lookup should find the issuer
      assert {:ok, ^issuer} = JwksCache.find_issuer_for_kid(kid)
    end

    test "returns :error for unknown kid" do
      assert :error = JwksCache.find_issuer_for_kid("unknown-kid")
    end
  end

  describe "force refresh" do
    test "clears JWKS and kid index for issuer" do
      issuer = "https://refresh-test.example.invalid"
      kid = "refresh-key"

      old_jwks = %{"keys" => [%{"kid" => kid, "kty" => "RSA"}]}
      context = %{jwks_overrides: %{issuer => old_jwks}}

      # Populate cache
      assert {:ok, _} = JwksCache.get_jwks(issuer, context)
      assert {:ok, ^issuer} = JwksCache.find_issuer_for_kid(kid)

      # Force refresh clears cache
      :ok = JwksCache.force_refresh(issuer)

      # Kid index should be cleared
      assert :error = JwksCache.find_issuer_for_kid(kid)

      # Next fetch should get fresh data
      new_jwks = %{"keys" => [%{"kid" => "new-key", "kty" => "RSA"}]}
      new_context = %{jwks_overrides: %{issuer => new_jwks}}
      assert {:ok, ^new_jwks} = JwksCache.get_jwks(issuer, new_context)
    end
  end

  describe "JWKS URL building" do
    test "uses oauth2 jwks endpoint for AuthKit issuers" do
      issuer = "https://tenant.authkit.app"
      {url, cache_key} = JwksCache.build_jwks_url(issuer, %{})

      assert url == "https://tenant.authkit.app/oauth2/jwks"
      assert cache_key == issuer
    end

    test "uses well-known JWKS endpoint for standard issuers" do
      issuer = "https://issuer.example.invalid"
      {url, cache_key} = JwksCache.build_jwks_url(issuer, %{})

      assert url == "https://issuer.example.invalid/.well-known/jwks.json"
      assert cache_key == issuer
    end
  end
end
