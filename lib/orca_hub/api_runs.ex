defmodule OrcaHub.ApiRuns do
  @moduledoc """
  Context for the Agent Runs API (docs/api.md) — CRUD for `api_runs` plus the
  pure helpers `ApiRunController`'s poll-driven state machine uses to pull a
  JSON result out of a session's final assistant text and validate it against
  a caller-supplied JSON Schema.
  """

  alias OrcaHub.ApiRuns.ApiRun
  alias OrcaHub.Repo

  def get_run(id) do
    case Repo.get(ApiRun, id) do
      nil -> nil
      run -> Repo.preload(run, :session)
    end
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
end
