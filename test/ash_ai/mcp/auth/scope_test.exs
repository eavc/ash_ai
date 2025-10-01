defmodule AshAi.Mcp.Auth.ScopeTest do
  use ExUnit.Case, async: true

  alias AshAi.Mcp.Auth.Scope

  describe "scopes_from_claims/1" do
    test "extracts scopes from space-separated string" do
      claims = %{"scope" => "read write admin"}
      assert Scope.scopes_from_claims(claims) == ["read", "write", "admin"]
    end

    test "extracts scopes from comma-separated string" do
      claims = %{"scope" => "read,write,admin"}
      assert Scope.scopes_from_claims(claims) == ["read", "write", "admin"]
    end

    test "extracts scopes from mixed separators" do
      claims = %{"scope" => "read, write admin"}
      assert Scope.scopes_from_claims(claims) == ["read", "write", "admin"]
    end

    test "extracts scopes from list of strings" do
      claims = %{"scope" => ["read", "write", "admin"]}
      assert Scope.scopes_from_claims(claims) == ["read", "write", "admin"]
    end

    test "extracts scopes from list of atoms" do
      claims = %{"scope" => [:read, :write, :admin]}
      assert Scope.scopes_from_claims(claims) == ["read", "write", "admin"]
    end

    test "extracts scopes from scp claim when scope is missing" do
      claims = %{"scp" => ["read", "write"]}
      assert Scope.scopes_from_claims(claims) == ["read", "write"]
    end

    test "prefers scope over scp when both present" do
      claims = %{"scope" => ["read", "write"], "scp" => ["admin"]}
      assert Scope.scopes_from_claims(claims) == ["read", "write"]
    end

    test "returns empty list when no scope claims" do
      claims = %{"sub" => "user:123"}
      assert Scope.scopes_from_claims(claims) == []
    end

    test "returns empty list for nil claims" do
      assert Scope.scopes_from_claims(nil) == []
    end

    test "returns empty list for empty map" do
      assert Scope.scopes_from_claims(%{}) == []
    end

    test "handles empty scope string" do
      claims = %{"scope" => ""}
      assert Scope.scopes_from_claims(claims) == []
    end

    test "handles empty scope list" do
      claims = %{"scope" => []}
      assert Scope.scopes_from_claims(claims) == []
    end

    test "trims whitespace from scopes" do
      claims = %{"scope" => "  read   write  "}
      assert Scope.scopes_from_claims(claims) == ["read", "write"]
    end
  end

  describe "missing_scopes/2" do
    test "returns empty list when all scopes granted" do
      required = ["read", "write"]
      granted = ["read", "write", "admin"]
      assert Scope.missing_scopes(required, granted) == []
    end

    test "returns missing scopes" do
      required = ["read", "write", "admin"]
      granted = ["read"]
      assert Scope.missing_scopes(required, granted) == ["write", "admin"]
    end

    test "is case-insensitive" do
      required = ["READ", "Write"]
      granted = ["read", "WRITE"]
      assert Scope.missing_scopes(required, granted) == []
    end

    test "returns all required when none granted" do
      required = ["read", "write"]
      granted = []
      assert Scope.missing_scopes(required, granted) == ["read", "write"]
    end

    test "returns empty when no scopes required" do
      required = []
      granted = ["read", "write"]
      assert Scope.missing_scopes(required, granted) == []
    end

    test "handles mixed case scopes correctly" do
      required = ["ReAd", "WrItE", "admin"]
      granted = ["READ", "write"]
      assert Scope.missing_scopes(required, granted) == ["admin"]
    end

    test "preserves original case of missing scopes" do
      required = ["READ", "WRITE", "ADMIN"]
      granted = ["read"]
      missing = Scope.missing_scopes(required, granted)
      assert missing == ["WRITE", "ADMIN"]
    end

    test "handles duplicate granted scopes" do
      required = ["read", "write"]
      granted = ["read", "read", "write", "write"]
      assert Scope.missing_scopes(required, granted) == []
    end

    test "handles duplicate required scopes" do
      required = ["read", "read", "write"]
      granted = ["read", "write"]
      assert Scope.missing_scopes(required, granted) == []
    end
  end

  describe "integration with OAuth flow" do
    test "real-world Auth0 token scenario" do
      # Auth0 typically uses space-separated scopes
      claims = %{
        "sub" => "auth0|123",
        "aud" => "https://api.example.com",
        "scope" => "openid profile email read:users write:users"
      }

      scopes = Scope.scopes_from_claims(claims)
      assert "openid" in scopes
      assert "read:users" in scopes

      required = ["read:users", "write:users"]
      missing = Scope.missing_scopes(required, scopes)
      assert missing == []
    end

    test "real-world Azure AD token scenario" do
      # Azure AD uses the scp claim
      claims = %{
        "sub" => "azure|456",
        "aud" => "https://api.example.com",
        "scp" => ["User.Read", "User.Write"]
      }

      scopes = Scope.scopes_from_claims(claims)
      assert "User.Read" in scopes
      assert "User.Write" in scopes
    end

    test "insufficient scope scenario" do
      claims = %{"scope" => "read"}
      scopes = Scope.scopes_from_claims(claims)

      required = ["read", "write", "admin"]
      missing = Scope.missing_scopes(required, scopes)

      assert missing == ["write", "admin"]
      assert length(missing) == 2
    end
  end
end
