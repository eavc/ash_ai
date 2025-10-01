defmodule AshAi.Mcp.Auth.ResourceMetadataTest do
  use ExUnit.Case, async: true
  import Plug.{Conn, Test}

  alias AshAi.Mcp.Auth.ResourceMetadata

  test "metadata endpoint returns RFC 9728 payload" do
    conn =
      conn(:get, "/.well-known/oauth-protected-resource")
      |> assign(:router_opts,
        public_base_url: "https://example.invalid",
        resource_path: "/mcp",
        authorization_servers: ["https://issuer.example.invalid"],
        required_scopes: ["read", "write"],
        resource_documentation: "https://docs.example.invalid/mcp",
        resource_signing_algorithms_supported: ["RS256"],
        token_endpoint_auth_methods_supported: ["client_secret_post"]
      )

    conn = ResourceMetadata.call(conn, ResourceMetadata.init([]))

    assert conn.status == 200
    assert conn.halted

    payload = Jason.decode!(conn.resp_body)

    assert payload["resource"] == "https://example.invalid/mcp"
    assert payload["authorization_servers"] == ["https://issuer.example.invalid"]
    assert payload["scopes_supported"] == ["read", "write"]
    assert payload["bearer_methods_supported"] == ["authorization_header"]
    assert payload["resource_documentation"] == "https://docs.example.invalid/mcp"
    assert payload["resource_signing_algorithms_supported"] == ["RS256"]
    assert payload["token_endpoint_auth_methods_supported"] == ["client_secret_post"]
  end

  test "authorization servers derive from verifier context issuers" do
    conn =
      conn(:get, "/.well-known/oauth-protected-resource")
      |> assign(:router_opts,
        public_base_url: "https://example.invalid",
        resource_path: "/mcp",
        verifier_context: [
          issuer: "https://issuer.example.invalid",
          issuers: ["https://tenant.example", "https://issuer.example.invalid"],
          authorization_servers: []
        ]
      )

    conn = ResourceMetadata.call(conn, ResourceMetadata.init([]))

    payload = Jason.decode!(conn.resp_body)

    assert payload["authorization_servers"] == [
             "https://issuer.example.invalid/.well-known/oauth-authorization-server",
             "https://tenant.example/.well-known/oauth-authorization-server"
           ]
  end
end
