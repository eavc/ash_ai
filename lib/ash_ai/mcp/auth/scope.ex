defmodule AshAi.Mcp.Auth.Scope do
  @moduledoc false

  @doc """
  Extract granted scopes from token claims.

  Supports common claim shapes across IdPs:
  - "scope": space- or comma-separated string, or list
  - "scp": list (e.g., Azure AD)
  - "permissions": list (e.g., Auth0 RFC 9068 authorization profile)

  Returned list is a flattened union with duplicates removed left to callers
  (callers typically only need presence checks).
  """
  @spec scopes_from_claims(map()) :: [String.t()]
  def scopes_from_claims(claims) when is_map(claims) do
    scope = Map.get(claims, "scope")
    scp = Map.get(claims, "scp")
    permissions = Map.get(claims, "permissions")

    # Base scopes come from `scope` if present; otherwise fall back to `scp`.
    scope_list =
      cond do
        is_binary(scope) -> String.split(scope, [" ", ","], trim: true)
        is_list(scope) -> Enum.map(scope, &to_string/1)
        is_list(scp) -> Enum.map(scp, &to_string/1)
        true -> []
      end

    perm_list =
      cond do
        is_list(permissions) -> Enum.map(permissions, &to_string/1)
        is_binary(permissions) -> String.split(permissions, [" ", ","], trim: true)
        true -> []
      end

    (scope_list ++ perm_list)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def scopes_from_claims(_), do: []

  @doc "Return required scopes that are missing from granted set (case-insensitive)."
  @spec missing_scopes([String.t()], [String.t()]) :: [String.t()]
  def missing_scopes(required, granted) do
    granted_downcased = Enum.map(granted, &String.downcase/1)

    Enum.reject(required, fn req -> String.downcase(req) in granted_downcased end)
  end
end
