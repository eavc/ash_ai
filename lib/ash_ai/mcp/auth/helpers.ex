defmodule AshAi.Mcp.Auth.Helpers do
  @moduledoc false

  alias AshAuthentication.Jwt

  @resource_metadata_path "/.well-known/oauth-protected-resource"
  @authorization_metadata_path "/.well-known/oauth-authorization-server"

  @doc """
  Normalizes list-like values into string lists, trimming whitespace and rejecting blanks.
  """
  @spec normalize_list_like(term()) :: [String.t()]
  def normalize_list_like(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
  end

  def normalize_list_like(value) do
    value
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  @doc """
  Ensures values are turned into a deduplicated, trimmed list.
  """
  @spec normalize_list(term()) :: [String.t()]
  def normalize_list(value) do
    value
    |> normalize_list_like()
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Normalizes a scope value into a list, rejecting blanks.
  """
  @spec normalize_scopes(term()) :: [String.t()]
  def normalize_scopes(value) do
    value
    |> normalize_list_like()
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Attempts to infer a public base URL from the request host when one is not explicitly configured.
  """
  @spec default_public_base_url(Plug.Conn.t()) :: String.t()
  def default_public_base_url(conn) do
    case Plug.Conn.get_req_header(conn, "host") do
      [host | _] ->
        scheme = if conn.scheme == :https, do: "https", else: "http"
        "#{scheme}://#{host}"

      _ ->
        raise ArgumentError,
              "Unable to determine MCP public URL. Configure :public_base_url or MCP_PUBLIC_URL"
    end
  end

  @doc """
  Builds the list of authorization servers, deriving from verifier context when not explicitly provided.
  """
  @spec derive_authorization_servers(term(), map()) :: [String.t()]
  def derive_authorization_servers(value, opts) do
    value
    |> normalize_authorization_value()
    |> case do
      [] -> authorization_servers_from_context(Map.get(opts, :verifier_context))
      list -> list
    end
  end

  @spec default_signing_algorithms([String.t()]) :: [String.t()]
  def default_signing_algorithms(authorization_servers) when is_list(authorization_servers) do
    if Enum.empty?(authorization_servers) do
      [Jwt.default_algorithm()]
    else
      ["RS256"]
    end
  end

  def default_signing_algorithms(_), do: [Jwt.default_algorithm()]

  @doc """
  Computes metadata for WWW-Authenticate error_uri parameter.
  """
  @spec build_error_uri(String.t() | nil) :: [{String.t(), String.t()}]
  def build_error_uri(nil), do: []

  def build_error_uri(base_url) do
    uri = String.trim_trailing(base_url, "/") <> @resource_metadata_path
    [{"error_uri", uri}]
  end

  @doc """
  Normalizes authorization server configuration values.
  """
  @spec normalize_authorization_value(term() | nil) :: [String.t()]
  def normalize_authorization_value(nil), do: []

  def normalize_authorization_value(value) do
    value
    |> normalize_list_like()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  @doc """
  Converts keyword or map contexts into maps to simplify downstream processing.
  """
  @spec mapify(map() | keyword() | nil) :: map()
  def mapify(value) when is_map(value), do: value
  def mapify(value) when is_list(value), do: Map.new(value)
  def mapify(_), do: %{}

  @doc """
  Derives authorization servers from verifier context data.
  """
  @spec authorization_servers_from_context(map() | keyword() | nil) :: [String.t()]
  def authorization_servers_from_context(context) do
    context = mapify(context)

    explicit =
      (Map.get(context, :authorization_servers) ||
         Map.get(context, "authorization_servers") || [])
      |> normalize_authorization_value()

    issuers =
      (Map.get(context, :issuers) || Map.get(context, "issuers") || [])
      |> normalize_authorization_value()

    issuer =
      case Map.get(context, :issuer) || Map.get(context, "issuer") do
        nil -> []
        value -> [to_string(value)]
      end

    issuer_servers =
      (issuer ++ issuers)
      |> Enum.map(&issuer_to_authorization_server/1)
      |> Enum.reject(&is_nil/1)

    explicit
    |> Enum.concat(issuer_servers)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Converts an issuer URL into its corresponding OAuth authorization server metadata endpoint.
  """
  @spec issuer_to_authorization_server(String.t() | nil) :: String.t() | nil
  def issuer_to_authorization_server(nil), do: nil

  def issuer_to_authorization_server(issuer) do
    issuer
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.trim_trailing(trimmed, "/") <> @authorization_metadata_path
    end
  end
end
