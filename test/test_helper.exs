# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

ExUnit.start()

AshAi.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(AshAi.TestRepo, :manual)
