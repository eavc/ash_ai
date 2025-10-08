# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Info do
  @moduledoc "Introspection functions for the `AshAi` extension."
  use Spark.InfoGenerator, extension: AshAi, sections: [:tools, :vectorize]
end
