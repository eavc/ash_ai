defmodule AshAi.Mcp.Auth.OAuthBearerPlugTest do
  use ExUnit.Case, async: false
  import Plug.{Conn, Test}

  alias AshAi.Mcp.Auth.OAuthBearerPlug

  defmodule FakeResource do
  end

  # Setup helper for managing MCP_PUBLIC_URL environment variable
  defp with_env(env_var, value, fun) do
    original = System.get_env(env_var)

    try do
      if value do
        System.put_env(env_var, value)
      else
        System.delete_env(env_var)
      end

      fun.()
    after
      if original do
        System.put_env(env_var, original)
      else
        System.delete_env(env_var)
      end
    end
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

  defp with_telemetry(events, fun) do
    handler_id = make_ref()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(self(), {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  test "missing authorization header returns 401" do
    conn = conn_with_opts(:post, "/", %{}, [])
    conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
    assert conn.halted
  end

  test "invalid token is rejected" do
    with_telemetry([[:ash_ai, :mcp, :oauth, :verify]], fn ->
      conn =
        conn_with_opts(:post, "/", %{}, [])
        |> put_req_header("authorization", "Bearer bad-token")

      conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

      assert conn.status == 401
      assert conn.halted
    end)

    assert_receive {
      :telemetry_event,
      [:ash_ai, :mcp, :oauth, :verify],
      %{duration: duration},
      %{status: :error, reason: :invalid_token}
    }

    assert is_integer(duration) and duration >= 0
  end

  test "optional mode allows absence of token" do
    conn = conn_with_opts(:post, "/", %{}, required?: false)

    conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init(required?: false))

    refute conn.halted
  end

  test "valid token assigns actor, tenant and claims" do
    with_telemetry([[:ash_ai, :mcp, :oauth, :verify]], fn ->
      conn =
        conn_with_opts(:post, "/", %{}, [])
        |> put_req_header("authorization", "Bearer tenant-token")

      conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

      refute conn.halted
      assert %{tenant: "acme"} = conn.private[:ash]
      assert %{tenant: "acme"} = Ash.PlugHelpers.get_actor(conn)
      assert conn.assigns.oauth_claims["sub"] == "user:tenant"
    end)

    assert_receive {
      :telemetry_event,
      [:ash_ai, :mcp, :oauth, :verify],
      %{duration: duration},
      %{status: :ok}
    }

    assert is_integer(duration) and duration >= 0
  end

  test "insufficient scopes respond with 403" do
    with_env("MCP_REQUIRED_SCOPES", "read", fn ->
      with_telemetry(
        [
          [:ash_ai, :mcp, :oauth, :verify],
          [:ash_ai, :mcp, :oauth, :insufficient_scope]
        ],
        fn ->
          conn =
            conn_with_opts(:post, "/", %{}, [])
            |> put_req_header("authorization", "Bearer scope-token")

          conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

          assert conn.status == 403
          [auth_header] = get_resp_header(conn, "www-authenticate")
          assert auth_header =~ "insufficient_scope"
        end
      )

      assert_receive {
        :telemetry_event,
        [:ash_ai, :mcp, :oauth, :verify],
        _measurements,
        %{status: :ok}
      }

      assert_receive {
        :telemetry_event,
        [:ash_ai, :mcp, :oauth, :insufficient_scope],
        %{count: 1} = measurements,
        %{missing_scopes: missing}
      }

      assert measurements[:count] == 1
      assert missing == ["read"]
    end)
  end

  test "scope enforcement disabled when MCP_REQUIRED_SCOPES blank" do
    with_env("MCP_REQUIRED_SCOPES", "", fn ->
      conn =
        conn_with_opts(:post, "/", %{}, [])
        |> put_req_header("authorization", "Bearer scope-token")

      conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

      refute conn.halted
      assert conn.status != 403
    end)
  end

  test "invalid resource indicator responds with 401" do
    with_telemetry(
      [
        [:ash_ai, :mcp, :oauth, :verify],
        [:ash_ai, :mcp, :oauth, :audience_mismatch]
      ],
      fn ->
        conn =
          conn_with_opts(:post, "/", %{}, [])
          |> put_req_header("authorization", "Bearer aud-token")

        conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))

        assert conn.status == 401
        [auth_header] = get_resp_header(conn, "www-authenticate")
        assert auth_header =~ "invalid_scope"
      end
    )

    assert_receive {
      :telemetry_event,
      [:ash_ai, :mcp, :oauth, :verify],
      _measurements,
      %{status: :ok}
    }

    assert_receive {
      :telemetry_event,
      [:ash_ai, :mcp, :oauth, :audience_mismatch],
      %{count: 1},
      %{resource_indicator: "https://example.invalid/mcp"}
    }
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

  test "additional WWW-Authenticate params are appended" do
    conn =
      conn_with_opts(:post, "/", %{},
        www_authenticate_params: [error_contact: "mailto:support@example.invalid"]
      )

    conn =
      conn
      |> put_req_header("authorization", "Bearer bad-token")
      |> OAuthBearerPlug.call(OAuthBearerPlug.init([]))

    [auth_header] = get_resp_header(conn, "www-authenticate")
    assert auth_header =~ "error_contact=\"mailto:support@example.invalid\""
  end

  test "missing public_base_url with required?=true raises ArgumentError" do
    with_env("MCP_PUBLIC_URL", nil, fn ->
      # Create opts without public_base_url
      opts = [
        otp_app: :ash_ai,
        resource_path: "/mcp",
        required_scopes: ["read"],
        verifier: &__MODULE__.verify/4,
        subject_resolver: &__MODULE__.resolve_subject/3,
        verify_target: :fake,
        required?: true
        # Note: public_base_url is missing
      ]

      conn = conn(:post, "/", %{}) |> assign(:router_opts, opts)

      assert_raise ArgumentError,
                   ~r/Unable to determine MCP public URL/,
                   fn ->
                     OAuthBearerPlug.call(conn, OAuthBearerPlug.init([]))
                   end
    end)
  end

  test "missing public_base_url with required?=false works" do
    with_env("MCP_PUBLIC_URL", nil, fn ->
      opts = [
        otp_app: :ash_ai,
        resource_path: "/mcp",
        required_scopes: ["read"],
        verifier: &__MODULE__.verify/4,
        subject_resolver: &__MODULE__.resolve_subject/3,
        verify_target: :fake,
        required?: false
        # Note: public_base_url is missing but auth is optional
      ]

      conn = conn(:post, "/", %{}) |> assign(:router_opts, opts)
      conn = OAuthBearerPlug.call(conn, OAuthBearerPlug.init(required?: false))

      # Should not raise and should not halt (auth is optional)
      refute conn.halted
    end)
  end
end
