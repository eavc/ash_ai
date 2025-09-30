defmodule AshAi.Mcp.Auth.Scope do
  @moduledoc false

  @doc "Extract granted scopes from token claims (space/comma separated or list)."
  @spec scopes_from_claims(map()) :: [String.t()]
  def scopes_from_claims(claims) when is_map(claims) do
    scope = Map.get(claims, "scope")

    cond do
      is_binary(scope) ->
        scope |> String.split([" ", ","], trim: true)

      is_list(scope) ->
        Enum.map(scope, &to_string/1)

      is_list(Map.get(claims, "scp")) ->
        Enum.map(claims["scp"], &to_string/1)

      true ->
        []
    end
  end

  def scopes_from_claims(_), do: []

  @doc "Return required scopes that are missing from granted set (case-insensitive)."
  @spec missing_scopes([String.t()], [String.t()]) :: [String.t()]
  def missing_scopes(required, granted) do
    granted_downcased = Enum.map(granted, &String.downcase/1)

    Enum.reject(required, fn req -> String.downcase(req) in granted_downcased end)
  end
end
