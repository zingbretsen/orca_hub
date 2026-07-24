defmodule OrcaHub.MCP.Tools.Databases do
  @moduledoc """
  MCP tools for provisioning PostgreSQL databases on the homelab shared
  postgres via pg-provisioner's JSON API
  (`https://pgprov.lab.ingbretsenhome.com/api/*`), so a session never has to
  fetch or hold the provisioner's bearer token itself — the hub infra holds
  `PGPROV_API_TOKEN` and makes the call on the session's behalf.

  Create-only, matching the API's own scope: pg-provisioner deliberately has
  no delete endpoint (`/drop` is UI-only, gated by Authelia SSO, human-only —
  see `postgres/provisioner/app.py` in the homelab repo). This module mirrors
  that: `provision_database` and `list_databases`, no `drop_database` tool.
  """
  import OrcaHub.MCP.Tools.Result

  @environments ~w(dev test prod)
  @default_environments ~w(dev)
  @name_regex ~r/^[a-z][a-z0-9_]{0,40}$/

  def list do
    [
      %{
        "name" => "provision_database",
        "description" =>
          "Provision a PostgreSQL database (+ dedicated owner role) per environment on the " <>
            "homelab shared postgres, via pg-provisioner. Re-running with an app/environment " <>
            "that already exists is a safe no-op (returns status \"exists\", no new " <>
            "credentials). A newly-created environment's result includes a ONE-TIME `dsn` " <>
            "(connection string with password) that is never stored server-side and cannot " <>
            "be retrieved again — store it in a k8s Secret (or equivalent) immediately, do " <>
            "not just leave it in chat/logs. There is no delete/drop tool: dropping a " <>
            "database is human-only, via the pg-provisioner web UI.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "app" => %{
              "type" => "string",
              "description" =>
                "App name — lowercase, starts with a letter, letters/digits/underscores " <>
                  "only, max 41 chars (e.g. \"myapp\"). Each environment gets its own " <>
                  "database named \"<app>_<environment>\"."
            },
            "environments" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => @environments},
              "description" =>
                "Subset of #{inspect(@environments)} to provision. Defaults to " <>
                  "#{inspect(@default_environments)} if omitted."
            }
          },
          "required" => ["app"]
        }
      },
      %{
        "name" => "list_databases",
        "description" =>
          "List every database on the homelab shared postgres: name, owner role, size, and " <>
            "whether it's protected from deletion. Use this to check what already exists " <>
            "before calling provision_database.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      }
    ]
  end

  def call("provision_database", args, _state) do
    with {:ok, app} <- validate_app(args["app"]),
         {:ok, environments} <- validate_environments(args["environments"]),
         {:ok, token} <- require_token() do
      do_provision(app, environments, token)
    else
      {:error, reason} -> error(reason)
    end
  end

  def call("list_databases", _args, _state) do
    with {:ok, token} <- require_token() do
      do_list_databases(token)
    else
      {:error, reason} -> error(reason)
    end
  end

  # ------------------------------------------------------------------
  # Validation
  # ------------------------------------------------------------------

  defp validate_app(app) when is_binary(app) do
    normalized = String.downcase(String.trim(app))

    if String.match?(normalized, @name_regex) do
      {:ok, normalized}
    else
      {:error,
       "app must be lowercase, start with a letter, and contain only letters, numbers, " <>
         "and underscores (max 41 chars), got: #{inspect(app)}"}
    end
  end

  defp validate_app(app),
    do: {:error, "app is required and must be a string, got: #{inspect(app)}"}

  defp validate_environments(nil), do: {:ok, @default_environments}

  defp validate_environments(environments) when is_list(environments) do
    normalized = environments |> Enum.map(&to_string/1) |> Enum.uniq()

    cond do
      normalized == [] ->
        {:ok, @default_environments}

      not Enum.all?(normalized, &(&1 in @environments)) ->
        {:error,
         "environments must be a subset of #{inspect(@environments)}, got: #{inspect(environments)}"}

      true ->
        {:ok, normalized}
    end
  end

  defp validate_environments(environments),
    do: {:error, "environments must be a list of strings, got: #{inspect(environments)}"}

  defp require_token do
    case Application.get_env(:orca_hub, :pgprov_api_token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        {:error,
         "PGPROV_API_TOKEN is not configured on this node — pg-provisioner tools are unavailable. " <>
           "Ask a human to check the node's env/secrets."}
    end
  end

  # ------------------------------------------------------------------
  # HTTP
  # ------------------------------------------------------------------

  defp do_provision(app, environments, token) do
    url = base_url() <> "/api/provision"
    body = %{"app" => app, "environments" => environments}

    case Req.post(url, [json: body, headers: auth_headers(token)] ++ req_opts()) do
      {:ok, %{status: 200, body: %{"results" => results}} = resp} ->
        text(Jason.encode!(%{app: resp.body["app"] || app, results: results}))

      {:ok, %{status: status, body: body}} ->
        error("pg-provisioner returned HTTP #{status}: #{inspect(body)}")

      {:error, reason} ->
        error("Failed to reach pg-provisioner: #{inspect(reason)}")
    end
  end

  defp do_list_databases(token) do
    url = base_url() <> "/api/databases"

    case Req.get(url, [headers: auth_headers(token)] ++ req_opts()) do
      {:ok, %{status: 200, body: %{"databases" => databases}}} ->
        text(Jason.encode!(databases))

      {:ok, %{status: status, body: body}} ->
        error("pg-provisioner returned HTTP #{status}: #{inspect(body)}")

      {:error, reason} ->
        error("Failed to reach pg-provisioner: #{inspect(reason)}")
    end
  end

  defp auth_headers(token), do: [{"authorization", "Bearer #{token}"}]

  defp base_url,
    do:
      Application.get_env(:orca_hub, :pgprov_api_url) ||
        "https://pgprov.lab.ingbretsenhome.com"

  defp req_opts, do: Application.get_env(:orca_hub, :pgprov_req_options, [])
end
