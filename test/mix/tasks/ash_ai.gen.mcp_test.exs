defmodule Mix.Tasks.AshAi.Gen.McpTest do
  use ExUnit.Case, async: true
  import Igniter.Test
  alias Rewrite
  alias Rewrite.Source

  @router_path "lib/demo_web/router.ex"
  @user_path "lib/demo/accounts/user.ex"

  test "configures OAuth by default" do
    {:ok, igniter, meta} =
      phx_test_project(app_name: :demo, files: default_user_resource())
      |> Igniter.compose_task("ash_ai.gen.mcp", ["--user", "Demo.Accounts.User"])
      |> apply_igniter()

    router_content = read_content(igniter, @router_path)

    assert router_content =~ "pipeline :mcp do"
    assert router_content =~ "AshAi.Mcp.Auth.OAuthBearerPlug"
    assert router_content =~ "public_base_url: System.fetch_env!(\"MCP_PUBLIC_URL\")"
    assert router_content =~ "forward \"/\", AshAi.Mcp.Router"
    refute router_content =~ "protocol_version_statement: \"2024-11-05\""

    assert Enum.any?(meta.notices, fn notice ->
             String.contains?(notice, "OAuth")
           end)
  end

  test "configures OIDC/JWKS with issuer flag" do
    {:ok, igniter, _meta} =
      phx_test_project(app_name: :demo, files: default_user_resource())
      |> Igniter.compose_task("ash_ai.gen.mcp", [
        "--user",
        "Demo.Accounts.User",
        "--issuer",
        "https://my-tenant.auth0.com",
        "--audience",
        "https://api.example.com/mcp"
      ])
      |> apply_igniter()

    router_content = read_content(igniter, @router_path)

    assert router_content =~ "pipeline :mcp do"
    assert router_content =~ "AshAi.Mcp.Auth.OAuthBearerPlug"
    assert router_content =~ "AshAi.Mcp.Auth.OidcJwksVerifier.verify"
    assert router_content =~ "issuer: System.fetch_env!(\"MCP_ISSUER\")"
    assert router_content =~ "resource_indicator: System.fetch_env!(\"MCP_RESOURCE_INDICATOR\")"
    assert router_content =~ "[\"RS256\"]"
    assert router_content =~ "authorization_servers:"
    assert router_content =~ "my-tenant.auth0.com/.well-known/oauth-authorization-server"
    assert router_content =~ "resource_signing_algorithms_supported:"
  end

  test "forward includes resource_indicator when issuer is configured" do
    {:ok, igniter, _meta} =
      phx_test_project(app_name: :demo, files: default_user_resource())
      |> Igniter.compose_task("ash_ai.gen.mcp", [
        "--user",
        "Demo.Accounts.User",
        "--issuer",
        "https://issuer.example.invalid",
        "--audience",
        "https://api.example.com/mcp"
      ])
      |> apply_igniter()

    router_content = read_content(igniter, @router_path)

    # Ensure the forward block includes both resource_indicator and authorization_servers
    assert Regex.match?(
             ~r/forward \"\/\"[\s\S]*resource_indicator:[\s\S]*authorization_servers:/,
             router_content
           )
  end

  test "allows disabling OAuth" do
    {:ok, igniter, meta} =
      phx_test_project(app_name: :demo, files: default_user_resource())
      |> Igniter.compose_task("ash_ai.gen.mcp", [
        "--user",
        "Demo.Accounts.User",
        "--no-oauth"
      ])
      |> apply_igniter()

    router_content = read_content(igniter, @router_path)

    refute router_content =~ "pipeline :mcp do"
    refute router_content =~ "AshAi.Mcp.Auth.OAuthBearerPlug"
    assert router_content =~ "public_base_url: System.get_env(\"MCP_PUBLIC_URL\")"

    assert Enum.any?(meta.notices, &String.contains?(&1, "not configured"))
  end

  test "supports legacy protocol flag" do
    {:ok, igniter, meta} =
      phx_test_project(app_name: :demo, files: default_user_resource())
      |> Igniter.compose_task(
        "ash_ai.gen.mcp",
        ["--user", "Demo.Accounts.User", "--allow-legacy-protocol"]
      )
      |> apply_igniter()

    router_content = read_content(igniter, @router_path)

    assert router_content =~ "protocol_version_statement: \"2024-11-05\""
    assert Enum.any?(meta.notices, &String.contains?(&1, "Legacy MCP protocol"))
  end

  test "supports custom path" do
    {:ok, igniter, _meta} =
      phx_test_project(app_name: :demo, files: default_user_resource())
      |> Igniter.compose_task("ash_ai.gen.mcp", [
        "--user",
        "Demo.Accounts.User",
        "--path",
        "/api/mcp"
      ])
      |> apply_igniter()

    router_content = read_content(igniter, @router_path)

    assert router_content =~ "scope \"/api/mcp\" do"
    assert router_content =~ "resource_path: \"/api/mcp\""
  end

  test "supports custom algorithms" do
    {:ok, igniter, _meta} =
      phx_test_project(app_name: :demo, files: default_user_resource())
      |> Igniter.compose_task("ash_ai.gen.mcp", [
        "--user",
        "Demo.Accounts.User",
        "--issuer",
        "https://auth.example.com",
        "--alg",
        "RS256,RS384,RS512"
      ])
      |> apply_igniter()

    router_content = read_content(igniter, @router_path)

    assert router_content =~ "[\"RS256\", \"RS384\", \"RS512\"]"
    assert router_content =~ "resource_signing_algorithms_supported:"
  end

  defp read_content(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Source.get(:content)
  end

  defp default_user_resource do
    %{
      @user_path => """
      defmodule Demo.Accounts.User do
        use Ash.Resource,
          data_layer: :embedded,
          extensions: [AshAuthentication]

        attributes do
          uuid_primary_key :id
        end

        authentication do
          strategies do
          end
        end
      end
      """
    }
  end
end
