defmodule OrcaHub.MCP.Tools.Files do
  @moduledoc """
  MCP tool for opening files in the session file viewer.
  """
  import OrcaHub.MCP.Tools.Result

  def list do
    [
      %{
        "name" => "open_file",
        "description" =>
          "Open a file in the user's session file viewer. The file will appear in a side panel next to the chat. Use this to show the user a file you've written or modified, or to pull up a reference file for discussion. Supports relative paths (within the project) and absolute paths (opened read-only if outside the project directory).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "file_path" => %{
              "type" => "string",
              "description" =>
                "The file path, either relative to the project directory (e.g. \"lib/my_app/module.ex\") or an absolute path (e.g. \"/home/user/other_project/file.ex\", opened read-only if outside project)"
            },
            "line" => %{
              "type" => "integer",
              "description" =>
                "Optional line number to scroll to when opening the file. The file viewer will highlight and scroll to this line."
            }
          },
          "required" => ["file_path"]
        }
      }
    ]
  end

  def call("open_file", args, state) do
    file_path = args["file_path"]
    line = args["line"]

    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection. Cannot open file in viewer.")

      session_id ->
        Phoenix.PubSub.broadcast(
          OrcaHub.PubSub,
          "session:#{session_id}",
          {:open_file, file_path, line}
        )

        line_msg = if line, do: " at line #{line}", else: ""
        text("Opened #{file_path}#{line_msg} in the session file viewer.")
    end
  end
end
