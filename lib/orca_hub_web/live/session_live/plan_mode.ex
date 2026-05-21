defmodule OrcaHubWeb.SessionLive.PlanMode do
  @moduledoc """
  Helpers for detecting and tracking Claude plan-mode state from the
  session message stream.

  Plan mode is driven by the `EnterPlanMode` / `ExitPlanMode` tool calls
  that appear in assistant messages.
  """

  @plans_dir Path.join(System.user_home!(), ".claude/plans")

  @doc "Directory where Claude writes plan files."
  def plans_dir, do: @plans_dir

  @doc """
  Reconstructs plan-mode state from session history.

  Returns `:planning` if the most recent plan-mode tool call was
  `EnterPlanMode`, otherwise `false`. The transient `:review` state is
  intentionally not reconstructed — it should only appear live when
  `ExitPlanMode` fires.
  """
  def detect(messages) do
    Enum.reduce(messages, false, &detect_from_message/2)
  end

  defp detect_from_message(%{"type" => "assistant", "message" => %{"content" => content}}, state)
       when is_list(content) do
    Enum.reduce(content, state, &detect_from_content/2)
  end

  defp detect_from_message(_msg, state), do: state

  defp detect_from_content(%{"type" => "tool_use", "name" => "EnterPlanMode"}, _), do: :planning
  defp detect_from_content(%{"type" => "tool_use", "name" => "ExitPlanMode"}, _), do: false
  defp detect_from_content(_, acc), do: acc
end
