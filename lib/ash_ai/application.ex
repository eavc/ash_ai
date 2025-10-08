# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AshAi.Mcp.Auth.JwksCache
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: AshAi.Supervisor
    )
  end
end
