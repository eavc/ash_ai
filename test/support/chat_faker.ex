# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshAi.ChatFaker do
  @moduledoc false
  @behaviour LangChain.ChatModels.ChatModel

  alias LangChain.Message

  defstruct [
    # required for chat models
    callbacks: [],
    expect_fun: nil
  ]

  def new!(attrs) do
    struct(__MODULE__, attrs)
  end

  @impl true
  def call(%__MODULE__{expect_fun: expect_fun} = chat_model, messages, tools)
      when is_list(messages) and is_list(tools) do
    case expect_fun do
      expect_fun when is_function(expect_fun) ->
        expect_fun.(chat_model, messages, tools)

      nil ->
        Message.new_assistant(%{content: "Good!"})
    end
  end

  @impl true
  def restore_from_map(_data) do
    raise "Not implemented"
  end

  @impl true
  def serialize_config(_model) do
    raise "Not implemented"
  end
end
