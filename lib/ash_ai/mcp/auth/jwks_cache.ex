defmodule AshAi.Mcp.Auth.JwksCache do
  @moduledoc """
  Supervised GenServer for managing JWKS (JSON Web Key Set) cache with security and performance optimizations.

  This GenServer provides:
  - Protected ETS table (prevents cache poisoning)
  - Async JWKS pre-warming to avoid blocking request threads
  - Kid-to-issuer index for fast multi-tenant lookups
  - Automatic cache expiration based on Cache-Control headers
  - Graceful handling of concurrent refresh requests

  ## Security

  The ETS table is `:protected`, meaning only this GenServer can write to it,
  preventing cache poisoning attacks from other processes.

  ## Performance

  - JWKS are pre-fetched asynchronously when nearing expiration
  - Kid index enables O(1) issuer lookup in multi-tenant scenarios
  - Read-optimized with `:read_concurrency`
  """

  use GenServer
  require Logger

  @table_name :ash_ai_jwks_cache
  @default_cache_ttl_seconds 900
  @refresh_threshold_seconds 60

  ## Client API

  @doc """
  Starts the JWKS cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets JWKS for a given issuer from cache or fetches it.

  Returns `{:ok, jwks}` or `{:error, reason}`.
  """
  @spec get_jwks(String.t(), map()) :: {:ok, map()} | {:error, any()}
  def get_jwks(issuer, context \\ %{}) do
    issuer = normalize_issuer(issuer)
    cache_key = {:jwks, issuer}

    case get_from_cache(cache_key) do
      {:ok, jwks} ->
        {:ok, jwks}

      :error ->
        GenServer.call(__MODULE__, {:fetch_jwks, issuer, context}, 30_000)
    end
  end

  @doc """
  Finds the issuer that contains a given kid.

  Uses the kid index for O(1) lookup in multi-tenant scenarios.
  Returns `{:ok, issuer}` or `:error`.
  """
  @spec find_issuer_for_kid(String.t()) :: {:ok, String.t()} | :error
  def find_issuer_for_kid(kid) do
    case :ets.lookup(@table_name, {:kid_index, kid}) do
      [{_key, issuer}] -> {:ok, issuer}
      [] -> :error
    end
  end

  @doc """
  Forces a refresh of JWKS for a given issuer.

  Used when signature verification fails and we need to fetch potentially rotated keys.
  This is synchronous to ensure the cache is cleared before subsequent fetches.
  """
  @spec force_refresh(String.t()) :: :ok
  def force_refresh(issuer) do
    issuer = normalize_issuer(issuer)
    GenServer.call(__MODULE__, {:force_refresh, issuer})
  end

  @doc """
  Clears the entire cache (primarily for testing).
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    GenServer.call(__MODULE__, :clear_cache)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table_name, [
        :named_table,
        :set,
        :protected,
        read_concurrency: true
      ])

    # Schedule periodic cleanup of expired entries
    schedule_cleanup()

    {:ok, %{table: table, pending_fetches: %{}, ref_to_issuer: %{}}}
  end

  @impl true
  def handle_call({:fetch_jwks, issuer, context}, from, state) do
    # Check if there's already a fetch in progress for this issuer
    case Map.get(state.pending_fetches, issuer) do
      nil ->
        # Start a new fetch
        task = Task.async(fn -> fetch_jwks_from_url(issuer, context) end)

        new_state =
          state
          |> put_in([:pending_fetches, issuer], {task, [from]})
          |> put_in([:ref_to_issuer, task.ref], issuer)

        {:noreply, new_state}

      {task, waiting_clients} ->
        # Add this client to the waiting list
        new_state = put_in(state.pending_fetches[issuer], {task, [from | waiting_clients]})
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:clear_cache, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:force_refresh, issuer}, _from, state) do
    # Delete from cache to force refetch
    :ets.delete(@table_name, {:jwks, issuer})

    # Also clear kid index entries for this issuer
    :ets.match_delete(@table_name, {{:kid_index, :_}, issuer})

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:prewarm, issuer}, state) do
    # Async pre-warm: fetch new JWKS in background and send back to GenServer
    parent = self()

    Task.start(fn ->
      case fetch_jwks_from_url(issuer, %{}) do
        {:ok, jwks, ttl} ->
          send(parent, {:prewarm_result, issuer, {:ok, jwks, ttl}})

        {:error, reason} ->
          send(parent, {:prewarm_result, issuer, {:error, reason}})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # O(1) lookup using ref_to_issuer map
    case Map.get(state.ref_to_issuer, ref) do
      nil ->
        {:noreply, state}

      issuer ->
        {_task, waiting_clients} = Map.fetch!(state.pending_fetches, issuer)

        # Process the result
        case result do
          {:ok, jwks, ttl} when is_map(jwks) ->
            store_jwks(issuer, jwks, ttl)
            reply_to_clients(waiting_clients, {:ok, jwks})

          {:ok, invalid, _ttl} ->
            Logger.error("JWKS fetch returned invalid data for #{issuer}: #{inspect(invalid)}")
            reply_to_clients(waiting_clients, {:error, :jwks_fetch_failed})

          {:error, reason} = error ->
            Logger.warning("Failed to fetch JWKS for #{issuer}: #{inspect(reason)}")
            reply_to_clients(waiting_clients, error)
        end

        # Remove from both maps
        new_state =
          state
          |> Map.update!(:pending_fetches, &Map.delete(&1, issuer))
          |> Map.update!(:ref_to_issuer, &Map.delete(&1, ref))

        # Demonitor the task
        Process.demonitor(ref, [:flush])

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # O(1) lookup using ref_to_issuer map
    case Map.get(state.ref_to_issuer, ref) do
      nil ->
        # Task ref not found (shouldn't happen, but defensive)
        {:noreply, state}

      issuer ->
        {_task, waiting_clients} = Map.fetch!(state.pending_fetches, issuer)
        Logger.error("JWKS fetch task crashed for #{issuer}: #{inspect(reason)}")
        reply_to_clients(waiting_clients, {:error, :jwks_fetch_failed})

        # Remove from both maps to prevent permanent wedge
        new_state =
          state
          |> Map.update!(:pending_fetches, &Map.delete(&1, issuer))
          |> Map.update!(:ref_to_issuer, &Map.delete(&1, ref))

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    now = System.system_time(:second)

    # Delete expired entries
    :ets.select_delete(@table_name, [
      {{{:jwks, :_}, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info({:prewarm_result, issuer, {:ok, jwks, ttl}}, state) do
    # Write the pre-warmed JWKS to cache (runs in GenServer process, so we have ETS write permission)
    store_jwks(issuer, jwks, ttl)
    Logger.debug("Pre-warmed JWKS cache for #{issuer}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:prewarm_result, issuer, {:error, reason}}, state) do
    Logger.warning("Failed to pre-warm JWKS for #{issuer}: #{inspect(reason)}")
    {:noreply, state}
  end

  ## Private Functions

  defp normalize_issuer(issuer) do
    issuer
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp get_from_cache(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] ->
        now = System.system_time(:second)

        if now < expires_at do
          # Check if we should pre-warm (refresh before expiry)
          if expires_at - now < @refresh_threshold_seconds do
            # Trigger async refresh (fire and forget)
            {:jwks, issuer} = key
            GenServer.cast(__MODULE__, {:prewarm, issuer})
          end

          {:ok, value}
        else
          :error
        end

      [] ->
        :error
    end
  end

  defp store_jwks(issuer, jwks, ttl) do
    expires_at = System.system_time(:second) + ttl
    :ets.insert(@table_name, {{:jwks, issuer}, jwks, expires_at})

    # Build kid index for fast lookup
    case Map.get(jwks, "keys") do
      keys when is_list(keys) ->
        Enum.each(keys, fn key ->
          if kid = Map.get(key, "kid") do
            :ets.insert(@table_name, {{:kid_index, kid}, issuer})
          end
        end)

      _ ->
        :ok
    end

    :ok
  end

  defp fetch_jwks_from_url(issuer, context) do
    # Validate issuer URL to prevent SSRF
    with :ok <- validate_issuer_url(issuer),
         {jwks_url, cache_key} <- build_jwks_url(issuer, context),
         {:ok, jwks, ttl} <- do_fetch_jwks(jwks_url, context, cache_key) do
      {:ok, jwks, ttl}
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_issuer_url(issuer) do
    uri = URI.parse(issuer)

    cond do
      uri.scheme != "https" ->
        {:error, :insecure_issuer}

      is_nil(uri.host) ->
        {:error, :invalid_issuer}

      uri.host in ["localhost", "127.0.0.1", "0.0.0.0"] ->
        {:error, :local_issuer}

      String.starts_with?(uri.host, "192.168.") ->
        {:error, :private_network}

      String.starts_with?(uri.host, "10.") ->
        {:error, :private_network}

      String.starts_with?(uri.host, "172.") ->
        # Check if it's in 172.16.0.0 - 172.31.255.255 range
        case String.split(uri.host, ".") do
          ["172", second | _] ->
            case Integer.parse(second) do
              {num, ""} when num >= 16 and num <= 31 -> {:error, :private_network}
              _ -> :ok
            end

          _ ->
            :ok
        end

      true ->
        :ok
    end
  end

  defp build_jwks_url(issuer, context) do
    issuer_host =
      issuer
      |> URI.parse()
      |> Map.get(:host)

    workos_client_id =
      Map.get(context, :workos_client_id) ||
        System.get_env("WORKOS_MCP_CLIENT_ID") ||
        System.get_env("WORKOS_CLIENT_ID")

    if issuer_host && String.ends_with?(issuer_host, ".authkit.app") &&
         is_binary(workos_client_id) do
      # WorkOS AuthKit serves JWKS from the WorkOS API instead of the issuer host.
      # We keep caching mapped to the original issuer so existing callers do not need
      # special handling.
      {"https://api.workos.com/sso/jwks/#{workos_client_id}", issuer}
    else
      {"#{issuer}/.well-known/jwks.json", issuer}
    end
  end

  defp do_fetch_jwks(jwks_url, context, cache_key) do
    # Check for test override
    overrides = Map.get(context, :jwks_overrides, %{})

    if jwks = Map.get(overrides, cache_key) do
      {:ok, jwks, @default_cache_ttl_seconds}
    else
      case Req.get(url: jwks_url, max_retries: 2, retry_delay: 100) do
        {:ok, %Req.Response{status: 200, body: body, headers: headers}} when is_map(body) ->
          ttl = parse_cache_ttl(headers)
          {:ok, body, ttl}

        {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
          case Jason.decode(body) do
            {:ok, map} ->
              ttl = parse_cache_ttl(headers)
              {:ok, map, ttl}

            _ ->
              Logger.warning("JWKS response not JSON from #{jwks_url}")
              {:error, :jwks_fetch_failed}
          end

        {:ok, %Req.Response{status: status}} ->
          Logger.warning("Failed to fetch JWKS from #{jwks_url}: HTTP #{status}")
          {:error, :jwks_fetch_failed}

        {:error, reason} ->
          Logger.warning("Failed to fetch JWKS from #{jwks_url}: #{inspect(reason)}")
          {:error, :jwks_fetch_failed}
      end
    end
  end

  defp parse_cache_ttl(headers) do
    headers
    |> Enum.find(fn {name, _value} -> String.downcase(name) == "cache-control" end)
    |> case do
      {_name, value} ->
        # Handle both string and list values (some HTTP clients return lists)
        value_str = value |> List.wrap() |> List.first() || ""

        case Regex.run(~r/max-age=(\d+)/i, value_str) do
          [_, seconds] -> String.to_integer(seconds)
          _ -> @default_cache_ttl_seconds
        end

      nil ->
        @default_cache_ttl_seconds
    end
  end

  defp reply_to_clients(clients, response) do
    Enum.each(clients, fn client ->
      GenServer.reply(client, response)
    end)
  end

  defp schedule_cleanup do
    # Clean up expired entries every 5 minutes
    Process.send_after(self(), :cleanup_expired, :timer.minutes(5))
  end
end
