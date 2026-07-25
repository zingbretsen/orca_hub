defmodule OrcaHub.ApiRuns do
  @moduledoc """
  Context for the Agent Runs API (docs/api.md) — CRUD for `api_runs` plus the
  pure helpers `ApiRunController`'s poll-driven state machine uses to pull a
  JSON result out of a session's final assistant text and validate it against
  a caller-supplied JSON Schema.
  """

  import Ecto.Query, only: [from: 2]

  alias OrcaHub.ApiRuns.ApiRun
  alias OrcaHub.Repo

  def get_run(id) do
    case Repo.get(ApiRun, id) do
      nil -> nil
      run -> Repo.preload(run, :session)
    end
  end

  @doc """
  The most recently created run for a session, or `nil`. Used by
  `SessionRunner` (ctx-build time) and `MCP.Server` (`tools/list`/`tools/call`
  for `api_run` connections, see `docs/api.md`) to look up a session's run
  by `orca_session_id`/`session_id` — a session is created fresh per
  `POST /api/v1/runs`, so there is normally at most one, but this is
  defensively ordered in case a session is ever reused across runs.
  """
  def get_run_by_session_id(session_id) do
    from(r in ApiRun,
      where: r.session_id == ^session_id,
      order_by: [desc: r.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  def create_run(attrs) do
    %ApiRun{}
    |> ApiRun.changeset(attrs)
    |> Repo.insert()
  end

  def update_run(%ApiRun{} = run, attrs) do
    run
    |> ApiRun.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Extracts a JSON value from raw assistant text: a bare JSON document, or one
  wrapped in a ```json (or bare ```) fenced code block. Returns `{:ok, term}`
  or `:error` if no JSON could be parsed.
  """
  @spec extract_json(String.t() | nil) :: {:ok, term} | :error
  def extract_json(nil), do: :error

  def extract_json(text) do
    trimmed = String.trim(text)

    case Jason.decode(trimmed) do
      {:ok, value} ->
        {:ok, value}

      {:error, _} ->
        case fenced_json_block(trimmed) do
          nil -> :error
          block -> Jason.decode(block) |> to_result()
        end
    end
  end

  defp fenced_json_block(text) do
    case Regex.run(~r/```(?:json)?\s*\n(.*?)```/s, text) do
      [_, block] -> String.trim(block)
      nil -> nil
    end
  end

  defp to_result({:ok, value}), do: {:ok, value}
  defp to_result({:error, _}), do: :error

  @doc """
  Validates `data` against the given raw (unresolved) JSON Schema map.

  Returns `:ok`, `{:error, errors}` with a list of human-readable messages
  (from a validation mismatch), or `{:schema_error, message}` if `schema`
  itself is not a valid JSON Schema.
  """
  @spec validate_against_schema(term, map) ::
          :ok | {:error, [String.t()]} | {:schema_error, String.t()}
  def validate_against_schema(data, schema) when is_map(schema) do
    resolved = ExJsonSchema.Schema.resolve(schema)

    case ExJsonSchema.Validator.validate(resolved, data) do
      :ok -> :ok
      {:error, errors} -> {:error, Enum.map(errors, &format_validation_error/1)}
    end
  rescue
    e -> {:schema_error, "invalid result_schema: #{Exception.message(e)}"}
  end

  defp format_validation_error(%ExJsonSchema.Validator.Error{error: error, path: path}) do
    "#{path}: #{error}"
  end

  defp format_validation_error(other), do: inspect(other)

  @doc """
  Validates the caller-supplied `client_tools` param on `POST /api/v1/runs`
  (docs/api.md, AG-UI-style client-defined tools): a list of
  `{"name", "description", "input_schema"}` maps with unique, non-empty
  names, none named `"submit_result"` (reserved for the schema-run result
  channel), and a map `input_schema` — actual JSON-Schema validity of
  `input_schema` isn't checked here (a malformed one just produces a less
  useful tool definition, same posture as `result_schema`). Non-object
  schemas are wrapped for tool advertisement downstream, at `MCP.Server`'s
  `tools/list` time, not here.

  Returns `{:ok, nil}` when `client_tools` wasn't given at all,
  `{:ok, normalized_list}` when valid, or `{:error, message}`.
  """
  @spec validate_client_tools(term) :: {:ok, [map] | nil} | {:error, String.t()}
  def validate_client_tools(nil), do: {:ok, nil}

  def validate_client_tools([]), do: {:error, "client_tools must be a non-empty list"}

  def validate_client_tools(tools) when is_list(tools) do
    with :ok <- validate_each_tool_shape(tools),
         :ok <- validate_unique_tool_names(tools) do
      {:ok, Enum.map(tools, &normalize_client_tool/1)}
    end
  end

  def validate_client_tools(_other), do: {:error, "client_tools must be a list"}

  defp validate_each_tool_shape(tools) do
    Enum.reduce_while(tools, :ok, fn tool, :ok ->
      case validate_tool_shape(tool) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_tool_shape(%{"name" => "submit_result"}) do
    {:error, "client_tools name \"submit_result\" is reserved"}
  end

  defp validate_tool_shape(%{
         "name" => name,
         "description" => description,
         "input_schema" => schema
       })
       when is_binary(name) and name != "" and is_binary(description) and is_map(schema) do
    :ok
  end

  defp validate_tool_shape(tool) do
    {:error,
     "each client_tools entry must have a non-empty \"name\" (string, not \"submit_result\"), " <>
       "a \"description\" (string), and an \"input_schema\" (object) — got #{inspect(tool)}"}
  end

  defp validate_unique_tool_names(tools) do
    names = Enum.map(tools, & &1["name"])

    if length(names) == length(Enum.uniq(names)) do
      :ok
    else
      {:error, "client_tools names must be unique"}
    end
  end

  defp normalize_client_tool(%{
         "name" => name,
         "description" => description,
         "input_schema" => schema
       }) do
    %{"name" => name, "description" => description, "input_schema" => schema}
  end
end
