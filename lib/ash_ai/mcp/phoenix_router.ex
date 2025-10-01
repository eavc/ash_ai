defmodule AshAi.Mcp.PhoenixRouter do
  @moduledoc """
  Wrapper that prepares options for `AshAi.Mcp.Router` with conventional environment lookups.

  Projects can expose a dedicated MCP router module and forward to it from their Phoenix router:

      defmodule MyAppWeb.McpRouter do
        use AshAi.Mcp.PhoenixRouter,
          otp_app: :my_app,
          path: "/mcp",
          env: [
            public_base_url: "MCP_PUBLIC_URL",
            required_scopes: "MCP_REQUIRED_SCOPES"
          ],
          resource_link_builder: &__MODULE__.resource_links/3,
          meta_builder: &__MODULE__.meta_builder/1

        def resource_links(tool, data, _context) do
          # Build Phoenix route-based links here
          []
        end

        def meta_builder(_ctx), do: %{}
      end

  The wrapper shares the same environment resolution behaviour as `AshAi.Mcp.PhoenixOAuthPlug`.
  Compile-time options are merged with runtime options, favouring runtime overrides.
  """

  defmacro __using__(opts \\ []) do
    quote bind_quoted: [opts: opts] do
      @behaviour Plug

      @ash_ai_router_opts AshAi.Mcp.PhoenixRouter.normalize_compile_opts(opts)

      @impl Plug
      def init(runtime_opts) do
        AshAi.Mcp.PhoenixRouter.prepare_options(runtime_opts, @ash_ai_router_opts)
      end

      @impl Plug
      def call(conn, opts) do
        AshAi.Mcp.Router.call(conn, opts)
      end
    end
  end

  @doc false
  def normalize_compile_opts(opts) when is_map(opts), do: Map.to_list(opts)
  def normalize_compile_opts(opts) when is_list(opts), do: opts
  def normalize_compile_opts(opts), do: List.wrap(opts)

  @doc false
  def prepare_options(runtime_opts, compile_opts) do
    runtime_opts = normalize_compile_opts(runtime_opts)
    compile_opts = normalize_compile_opts(compile_opts)

    AshAi.Mcp.PhoenixOAuthPlug.prepare_options(runtime_opts, compile_opts)
    |> ensure_resource_path()
  end

  defp ensure_resource_path(opts) do
    Keyword.update(opts, :resource_path, "/mcp", &normalize_path/1)
  end

  defp normalize_path(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end
end
