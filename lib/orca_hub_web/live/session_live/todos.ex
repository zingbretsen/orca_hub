defmodule OrcaHubWeb.SessionLive.Todos do
  @moduledoc """
  Helpers for extracting Claude `TodoWrite` todo lists from the session
  message stream.
  """

  @doc """
  Extracts the most recent todo list from a list of session messages.

  Returns the todos from the latest message containing a `TodoWrite`
  tool call, or `[]` if none is found.
  """
  def from_messages(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value([], &from_event/1)
  end

  @doc """
  Extracts the todo list from a single streamed event.

  Returns the parsed todos when the event contains a `TodoWrite` tool
  call, or `nil` otherwise.
  """
  def from_event(%{"type" => "assistant", "message" => %{"content" => content}})
      when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use" && &1["name"] == "TodoWrite"))
    |> List.last()
    |> case do
      nil -> nil
      tool_use -> parse(get_in(tool_use, ["input", "todos"]))
    end
  end

  def from_event(_event), do: nil

  @doc "Normalizes a `TodoWrite` `todos` argument into a list."
  def parse(todos) when is_list(todos), do: todos

  def parse(todos) when is_binary(todos) do
    case Jason.decode(todos) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  def parse(_), do: []
end
