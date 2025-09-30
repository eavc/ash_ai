defmodule Mix.Tasks.AshAi.Gen.Mcp.Docs do
  @moduledoc false

  def short_doc do
    "Sets up an MCP server for your application"
  end

  def example do
    "mix ash_ai.gen.mcp --api-key"
  end

  def long_doc do
    """
    #{short_doc()}

    Adds an IdP-agnostic MCP server to your router with OAuth 2.1 bearer token support.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--user` - The Ash resource for authentication (required when using OAuth)
    * `--issuer` - OAuth/OIDC issuer URL (e.g., "https://my-tenant.auth0.com")
    * `--audience` - Expected audience/resource indicator (e.g., "https://api.example.com/mcp")
    * `--alg` - Comma-separated signing algorithms (default: "RS256")
    * `--path` - MCP endpoint path (default: "/mcp")

    ## Flags

    * `--no-oauth` - Skip OAuth authentication setup (not recommended for production)
    * `--allow-legacy-protocol` - Support legacy MCP protocol version (2024-11-05)

    ## OAuth Configuration

    When OAuth is enabled (default), you must configure:

    * `MCP_PUBLIC_URL` - Your application's public URL
    * `MCP_REQUIRED_SCOPES` - Required OAuth scopes (space or comma-separated)

    If using OIDC/JWKS verification with `--issuer`:

    * The generator scaffolds OIDC/JWKS verifier usage
    * Set `authorization_servers` in resource metadata
    * Defaults to RS256 signing algorithm

    ## Examples

        # Basic OAuth setup with OIDC/JWKS
        mix ash_ai.gen.mcp \\
          --user MyApp.Accounts.User \\
          --issuer "https://my-tenant.auth0.com" \\
          --audience "https://api.example.com/mcp"

        # Custom signing algorithms
        mix ash_ai.gen.mcp \\
          --user MyApp.Accounts.User \\
          --issuer "https://auth.example.com" \\
          --alg "RS256,RS384"

        # Without OAuth (not recommended for production)
        mix ash_ai.gen.mcp --no-oauth

        # Legacy protocol support (for transition period)
        mix ash_ai.gen.mcp --allow-legacy-protocol
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshAi.Gen.Mcp do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_ai,
        example: __MODULE__.Docs.example(),
        schema: [
          oauth: :boolean,
          allow_legacy_protocol: :boolean,
          user: :string,
          issuer: :string,
          audience: :string,
          alg: :string,
          path: :string
        ],
        defaults: [
          oauth: true,
          allow_legacy_protocol: false,
          path: "/mcp"
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      oauth? = Keyword.get(igniter.args.options, :oauth, true)
      allow_legacy_protocol? = Keyword.get(igniter.args.options, :allow_legacy_protocol, false)
      issuer = Keyword.get(igniter.args.options, :issuer)
      audience = Keyword.get(igniter.args.options, :audience)
      alg = Keyword.get(igniter.args.options, :alg, "RS256")
      path = Keyword.get(igniter.args.options, :path, "/mcp")

      otp_app = Igniter.Project.Application.app_name(igniter)

      {igniter, router} =
        Igniter.Libs.Phoenix.select_router(
          igniter,
          "Which router should Ash AI be installed into?"
        )

      {igniter, user} = user_module(igniter)

      {igniter, mcp_scope?} =
        maybe_setup_oauth(igniter, router, oauth?, user, otp_app, issuer, audience, alg, path)

      pipe_through =
        if mcp_scope? do
          "pipe_through :mcp"
        end

      if router do
        {igniter, endpoints} = Igniter.Libs.Phoenix.endpoints_for_router(igniter, router)
        endpoint = Enum.at(endpoints, 0)

        forward_block =
          forward_body(otp_app, oauth?, issuer, alg, path, allow_legacy_protocol?)

        igniter =
          Igniter.Libs.Phoenix.add_scope(
            igniter,
            path,
            """
            #{pipe_through}

            #{forward_block}
            """,
            router: router
          )
          |> add_plug_to_endpoint(endpoint, otp_app, path)

        if allow_legacy_protocol? do
          Igniter.add_notice(
            igniter,
            "Legacy MCP protocol enabled for this scope. Remove `--allow-legacy-protocol` once clients upgrade to 2025-06-18."
          )
        else
          igniter
        end
      end
    end

    @doc false
    def add_plug_to_endpoint(igniter, endpoint, otp_app, path) do
      Igniter.Project.Module.find_and_update_module!(igniter, endpoint, fn zipper ->
        with {:ok, zipper} <- Igniter.Code.Common.move_to(zipper, &code_reloading?/1),
             {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
          {:ok,
           Igniter.Code.Common.add_code(
             zipper,
             """
             plug AshAi.Mcp.Dev,
               # For many tools, you will need to set the `protocol_version_statement` to the older version.
               protocol_version_statement: "2024-11-05",
               otp_app: :#{otp_app},
               path: "#{path}"
             """,
             placement: :before
           )}
        else
          :error ->
            {:warning,
             """
             Could not find the section of your endpoint `#{inspect(endpoint)}` dedicated to dev plugs.
             We look for `if code_reloading? do`, but you may have customized this code.
             Please add the plug manually, for example:

             if code_reloading? do
               plug AshAi.Mcp.Dev, otp_app: :#{otp_app}, path: "#{path}"
             end
             """}
        end
      end)
    end

    defp code_reloading?(zipper) do
      Igniter.Code.Function.function_call?(
        zipper,
        :if,
        2
      ) &&
        Igniter.Code.Function.argument_matches_predicate?(
          zipper,
          0,
          &Igniter.Code.Common.variable?(&1, :code_reloading?)
        )
    end

    defp user_module(igniter) do
      if igniter.args.options[:user] do
        {igniter, Igniter.Project.Module.parse(igniter.args.options[:user])}
      else
        default =
          Igniter.Project.Module.module_name(igniter, "Accounts.User")

        {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, default)

        if exists? do
          {igniter, default}
        else
          {igniter, nil}
        end
      end
    end

    defp maybe_setup_oauth(igniter, router, true, user, otp_app, issuer, audience, alg, path) do
      cond do
        is_nil(router) ->
          {igniter, false}

        is_nil(user) ->
          igniter
          |> Igniter.add_notice(
            "OAuth was requested but no user resource was found. Provide --user or configure authentication manually."
          )
          |> then(&{&1, false})

        true ->
          igniter =
            if issuer && !String.starts_with?(issuer, "https://") do
              Igniter.add_notice(igniter, "Issuer should use https:// scheme: #{issuer}")
            else
              igniter
            end

          setup_oauth_pipeline(igniter, router, user, otp_app, issuer, audience, alg, path)
      end
    end

    defp maybe_setup_oauth(
           igniter,
           _router,
           false,
           _user,
           _otp_app,
           _issuer,
           _audience,
           _alg,
           _path
         ) do
      igniter =
        Igniter.add_notice(
          igniter,
          "OAuth was not configured. Ensure your MCP endpoint is protected before exposing structured tools."
        )

      {igniter, false}
    end

    defp setup_oauth_pipeline(
           igniter,
           router,
           user,
           otp_app,
           issuer,
           audience,
           alg,
           path
         ) do
      algorithms = parse_algorithms(alg)

      pipeline_body =
        if issuer do
          # OIDC/JWKS setup with OidcJwksVerifier
          """
          plug AshAi.Mcp.Auth.OAuthBearerPlug,
            otp_app: :#{otp_app},
            verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4,
            verifier_context: [
              issuer: System.fetch_env!("MCP_ISSUER"),
              resource_indicator: System.fetch_env!("MCP_RESOURCE_INDICATOR"),
              actor_resource: #{inspect(user)},
              algorithms: #{inspect(algorithms)}
            ],
            public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
            resource_path: "#{path}",
            resource_indicator: System.fetch_env!("MCP_RESOURCE_INDICATOR"),
            required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
            required?: true
          """
        else
          # Default AshAuthentication JWT verification
          """
          plug AshAi.Mcp.Auth.OAuthBearerPlug,
            otp_app: :#{otp_app},
            public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
            resource_path: "#{path}",
            required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
            required?: true
          """
        end

      igniter =
        Igniter.Libs.Phoenix.add_pipeline(
          igniter,
          :mcp,
          pipeline_body,
          router: router
        )

      igniter =
        if issuer do
          igniter
          |> Igniter.add_notice("""
          OAuth pipeline added for MCP with OIDC/JWKS verification.
          Configure these environment variables:
          - MCP_ISSUER=#{issuer}
          - MCP_RESOURCE_INDICATOR=#{audience || "https://your-app.com/mcp"}
          - MCP_PUBLIC_URL=https://your-app.com
          - MCP_REQUIRED_SCOPES=\"mcp:access\"

          Also update the actor_resource in the pipeline to match your user resource.
          See documentation/topics/mcp_oauth.md for more details.
          """)
          |> then(fn ign ->
            if is_nil(audience) do
              Igniter.add_notice(
                ign,
                "No --audience provided. Ensure MCP_RESOURCE_INDICATOR is set to your IdP API identifier to avoid audience mismatches."
              )
            else
              ign
            end
          end)
        else
          Igniter.add_notice(
            igniter,
            """
            OAuth pipeline added for MCP.
            Configure these environment variables:
            - MCP_PUBLIC_URL=https://your-app.com
            - MCP_REQUIRED_SCOPES="mcp:access"

            See documentation/topics/mcp_oauth.md for configuration guidance.
            """
          )
        end

      {igniter, true}
    end

    defp parse_algorithms(alg_string) do
      alg_string
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.trim/1)
    end

    defp forward_body(otp_app, oauth?, issuer, alg, path, allow_legacy_protocol?) do
      algorithms = parse_algorithms(alg)

      base = [
        "forward \"/\", AshAi.Mcp.Router,",
        "  otp_app: :#{otp_app},",
        "  resource_path: \"#{path}\","
      ]

      oauth_lines =
        if oauth? do
          if issuer do
            # OIDC/JWKS configuration with authorization_servers
            auth_server =
              String.trim_trailing(issuer, "/") <> "/.well-known/oauth-authorization-server"

            [
              "  public_base_url: System.fetch_env!(\"MCP_PUBLIC_URL\"),",
              "  resource_indicator: System.fetch_env!(\"MCP_RESOURCE_INDICATOR\"),",
              "  authorization_servers: [\"#{auth_server}\"],",
              "  resource_signing_algorithms_supported: #{inspect(algorithms)},",
              "  required_scopes: System.fetch_env!(\"MCP_REQUIRED_SCOPES\"),",
              "  oauth_required?: true,"
            ]
          else
            # Default configuration
            [
              "  public_base_url: System.get_env(\"MCP_PUBLIC_URL\"),",
              "  required_scopes: System.get_env(\"MCP_REQUIRED_SCOPES\"),",
              "  oauth_required?: true,"
            ]
          end
        else
          [
            "  public_base_url: System.get_env(\"MCP_PUBLIC_URL\"),",
            "  required_scopes: System.get_env(\"MCP_REQUIRED_SCOPES\"),"
          ]
        end

      protocol_line =
        if allow_legacy_protocol? do
          ["  protocol_version_statement: \"2024-11-05\","]
        else
          []
        end

      footer = [
        "  # See documentation/topics/mcp_oauth.md for configuration guidance.",
        "  tools: [",
        "    # :tool1,",
        "    # :tool2",
        "  ]"
      ]

      (base ++ oauth_lines ++ protocol_line ++ footer)
      |> Enum.join("\n")
    end
  end
else
  defmodule Mix.Tasks.AshAi.Gen.Mcp do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_ai.gen.mcp' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
