defmodule AshAi.Mcp.Auth.OAuthBearerPlugTest do
  use ExUnit.Case, async: true
  import Plug.{Conn, Test}

  alias AshAi.Mcp.Auth.OAuthBearerPlug

  defmodule FakeResource do
  end

  defp base_opts(overrides) do
    [
      otp_app: :ash_ai,
      public_base_url: "https://example.invalid",
      resource_path: "/mcp",
      required_scopes: ["read"],
      verifier: &__MODULE__.verify/4,
      subject_resolver: &__MODULE__.resolve_subject/3,
      verify_target: :fake
    ] ++ overrides
  end

  defp conn_with_opts(method, path, body, opts) do
    conn(method, path, body)
    |> assign(:router_opts, base_opts(opts))
  end

  def verify("valid-token", _target, _opts, _ctx),
    do:
      {:ok, %{"sub" => "user:123", "aud" => "https://example.invalid/mcp", "scope" => "read"},
       FakeResource}

  def verify("scope-token", _target, _opts, _ctx),
    do:
      {:ok, %{"sub" => "user:123", "aud" => "https://example.invalid/mcp", "scope" => "profile"},
       FakeResource}

  def verify("aud-token", _target, _opts, _ctx),
    do:
      {:ok, %{"sub" => "user:123", "aud" => "https://wrong/mcp", "scope" => "read"}, FakeResource}

  def verify("tenant-token", _target, _opts, _ctx),
    do:
      {:ok,
       %{
         "sub" => "user:tenant",
         "aud" => "https://example.invalid/mcp",
         "scope" => "read",
         "tenant" => "acme"
       }, FakeResource}

  def verify(_, _target, _opts, _ctx), do: :error

  def resolve_subject("user:" <> id, _resource, opts) do
    tenant = Keyword.get(opts, :tenant)
    {:ok, %{id: id, tenant: tenant}}
  end

  def resolve_subject(_, _, _),
    do: {:error, 401, "invalid_token", "unknown_subject", "Unable to resolve subject", []}

  test "missing authorization header returns 401" do
    conn = conn_with_opts(:post, "/", %{}, [])
    conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
    assert conn.halted
  end

  test "invalid token is rejected" do
    conn =
      conn_with_opts(:post, "/", %{}, [])
      |> put_req_header("authorization", "Bearer bad-token")

    conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

    assert conn.status == 401
    assert conn.halted
  end

  test "optional mode allows absence of token" do
    conn = conn_with_opts(:post, "/", %{}, required?: false)

    conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init(required?: false))

    refute conn.halted
  end

  test "valid token assigns actor, tenant and claims" do
    conn =
      conn_with_opts(:post, "/", %{}, [])
      |> put_req_header("authorization", "Bearer tenant-token")

    conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

    refute conn.halted
    assert %{tenant: "acme"} = conn.private[:ash]
    assert %{tenant: "acme"} = Ash.PlugHelpers.get_actor(conn)
    assert conn.assigns.oauth_claims["sub"] == "user:tenant"
  end

  test "insufficient scopes respond with 403" do
    conn =
      conn_with_opts(:post, "/", %{}, [])
      |> put_req_header("authorization", "Bearer scope-token")

    conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

    assert conn.status == 403
    [auth_header] = get_resp_header(conn, "www-authenticate")
    assert auth_header =~ "insufficient_scope"
  end

  test "invalid resource indicator responds with 401" do
    conn =
      conn_with_opts(:post, "/", %{}, [])
      |> put_req_header("authorization", "Bearer aud-token")

    conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

    assert conn.status == 401
    [auth_header] = get_resp_header(conn, "www-authenticate")
    assert auth_header =~ "invalid_scope"
  end

  test "WWW-Authenticate includes resource and error_uri" do
    conn = conn_with_opts(:post, "/", %{}, [])
    conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

    assert conn.status == 401
    [auth_header] = get_resp_header(conn, "www-authenticate")
    assert auth_header =~ "resource=\"https://example.invalid/mcp\""

    assert auth_header =~
             "error_uri=\"https://example.invalid/.well-known/oauth-protected-resource\""
  end
end
