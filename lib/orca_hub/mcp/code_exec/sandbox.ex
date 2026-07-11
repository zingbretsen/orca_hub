defmodule OrcaHub.MCP.CodeExec.Sandbox do
  @moduledoc """
  A lightweight custom evaluator for model-authored Elixir that may call the
  generated `Tools.*` functions and stitch results together with pure stdlib —
  but may **not** touch OrcaHub internals (Repo, contexts) or obviously-dangerous
  stdlib (System, File, Code, Port, ...).

  This is a SINGLE-USER platform: the goal is a clean allowlist that is *good
  enough*, not airtight. Determined bypasses via `apply/3`, `Module.concat/1`,
  `String.to_existing_atom |> :erlang.apply`, etc. are explicitly out of scope
  (see "Known gaps" below).

  ## How it works

  1. Parse with `Code.string_to_quoted/2` (preserving line metadata).
  2. Walk the AST (`Macro.prewalk`) and reject the snippet if it references any
     module **not** on the allowlist, or calls a denied local builtin. The
     allowlist is positive: only `@allowed_modules` plus the generated `Tools`
     namespace are permitted. Because it is an allowlist, anything under
     `OrcaHub.*` (and `System`, `File`, `:os`, ...) is rejected for free — but we
     also keep an explicit `@denied_modules` denylist so the rejection reason is
     precise and the intent is documented.
  3. Install the caller's MCP `state` in the eval process's dictionary (so the
     generated `Tools.*` functions can read it), redirect stdout to a capped
     `StringIO`, and evaluate inside a `Task` with a wall-clock timeout.

  ## Result tuples

    * `{:ok, %{value: term, stdout: binary, binding: keyword}}` — `binding` is
      the resulting variable binding after the snippet ran, for callers that
      want to persist it across evals (see `OrcaHub.MCP.CodeExec.BindingStore`)
    * `{:error, {:rejected, reason}}`   — failed parsing/allowlist (the model
      should FIX its code: syntax error, denied module)
    * `{:error, {:timeout, ms}}`        — ran too long (resource outcome)
    * `{:error, {:exception, %{banner: binary, line: integer | nil,
      stdout: binary, partial_binding: keyword, statement: pos_integer,
      statement_count: pos_integer}}}` — ran and raised/threw (a tool or
      expression outcome, e.g. `Tools.Error`); `banner` is trimmed of internal
      eval/Task frames and `line` points at the offending line of the snippet.
      Top-level statements are evaluated sequentially (see "Sequential
      top-level evaluation" below), so `partial_binding` carries whatever was
      bound by the statements that completed before the one that raised
      (`statement` of `statement_count`, 1-indexed) — callers that persist
      bindings across evals (`OrcaHub.MCP.CodeExec.BindingStore`) can keep
      that partial progress instead of discarding it.

  ## Sequential top-level evaluation

  A snippet's top-level statements (the entries of its `:__block__`, or the
  single expression itself when there's no block) are evaluated one at a time
  via `Code.eval_quoted_with_env/4`, threading the binding *and* env forward
  so `require`/`import`/`alias` in one top-level statement still apply to
  later ones. If statement N raises, statements `1..N-1` already committed
  their bindings — those are surfaced as `partial_binding` above instead of
  being lost with the rest of the snippet. A snippet that never raises is
  unaffected: the last statement's value is returned exactly as a whole-block
  `Code.eval_quoted/3` would have produced.

  ## Known gaps (acceptable for a single-user tool)

    * `apply/3`, `Module.concat/1` + dynamic atoms can reach denied modules at
      runtime — we block the obvious local builtins but not all dynamic-dispatch
      tricks.
    * No memory/reduction limit (only wall-clock + output-size caps).
  """

  require Logger

  alias OrcaHub.MCP.CodeExec

  # Pure stdlib we consider safe + helpful for stitching tool results.
  @allowed_modules ~w(
    Enum Stream Map MapSet Keyword List Tuple Range
    String Integer Float Kernel Function
    Jason Base URI Regex IO Inspect
    Date Time DateTime NaiveDateTime Calendar
    Access
  )a

  # Explicit denylist — redundant with the allowlist (these aren't allowed
  # anyway) but kept for precise error messages + documented intent.
  @denied_modules ~w(System File Code Port Node Process Task Agent GenServer Kernel.ParallelCompiler IO.ANSI)a
  @denied_erlang_modules ~w(os erlang file code init net_kernel rpc ets dets)a

  # Local builtins that enable dynamic dispatch / side effects.
  @denied_locals ~w(apply spawn spawn_link spawn_monitor send exit throw receive)a

  # Actionable hint appended to rejections for OS/filesystem/process-style
  # modules — the model's next move is to look for a tool, not retry the call.
  @no_sandbox_access_hint "the sandbox has no filesystem/OS access — look for a tool instead, e.g. Tools.search(\"...\")"

  @default_timeout_ms 30_000
  @default_max_output 50_000

  # Synthetic file name attributed to the snippet's frames, so we can keep the
  # snippet's own line numbers and drop internal eval/Task plumbing frames.
  @snippet_file "run_elixir"

  @doc """
  Evaluate `code` (a string) in the sandbox.

  Options:

    * `:state`      — MCP state map installed in the eval process dictionary for
      the generated `Tools.*` functions to read (default `%{}`)
    * `:binding`    — input variable binding to evaluate against, e.g. the
      binding returned by a prior `eval/2` call (default `[]`)
    * `:timeout_ms` — wall-clock timeout (default 30_000; snippets are meant to
      batch several serial upstream/network tool calls)
    * `:max_output` — byte cap for captured stdout + formatted output
      (default 50_000)
  """
  def eval(code, opts \\ []) when is_binary(code) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_output = Keyword.get(opts, :max_output, @default_max_output)
    state = Keyword.get(opts, :state, %{})
    binding = Keyword.get(opts, :binding, [])

    with {:ok, ast} <- parse(code),
         :ok <- check(ast) do
      run(ast, state, binding, timeout, max_output)
    else
      {:rejected, reason} -> {:error, {:rejected, reason}}
      {:error, {:rejected, _}} = err -> err
    end
  end

  # ── parse + static check ─────────────────────────────────────────────

  defp parse(code) do
    case Code.string_to_quoted(code, file: @snippet_file, columns: true) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {_meta, msg, token}} ->
        {:error, {:rejected, "syntax error: #{inspect(msg)} #{inspect(token)}"}}
    end
  end

  @doc """
  Statically validate an AST against the allowlist. Public so tests can assert
  on it directly without evaluating.
  """
  def check(ast) do
    Macro.prewalk(ast, :ok, fn node, acc -> {node, acc_check(node, acc)} end)
    |> elem(1)
  end

  # Once rejected, stay rejected (don't overwrite the first reason).
  defp acc_check(_node, {:rejected, _} = rejected), do: rejected

  # Aliased module reference: {:__aliases__, _, [:OrcaHub, :Repo]}
  defp acc_check({:__aliases__, _meta, parts}, :ok) when is_list(parts) do
    validate_module(parts)
  end

  # Erlang-style remote call: {{:., _, [:os, :cmd]}, _, args}
  defp acc_check({{:., _, [mod, _fun]}, _, _args}, :ok) when is_atom(mod) do
    if mod in @denied_erlang_modules do
      reject("erlang module :#{mod} is not allowed — #{@no_sandbox_access_hint}")
    else
      :ok
    end
  end

  # Local call: {:apply, _, [..]} — only when it's actually a call (args list).
  defp acc_check({name, _meta, args}, :ok) when is_atom(name) and is_list(args) do
    if name in @denied_locals do
      reject("local builtin `#{name}` is not allowed")
    else
      :ok
    end
  end

  defp acc_check(_node, acc), do: acc

  # First segment decides the namespace. `Tools.*` is the generated surface.
  defp validate_module([root | _] = parts) do
    cond do
      root == :Tools ->
        :ok

      root in @denied_modules ->
        reject("module #{Enum.join(parts, ".")} is denied — #{@no_sandbox_access_hint}")

      root in @allowed_modules ->
        :ok

      root == :OrcaHub ->
        reject(
          "OrcaHub.* internals are not accessible from the sandbox " <>
            "(#{Enum.join(parts, ".")}) — call the corresponding Tools.* function instead"
        )

      true ->
        reject(
          "module #{Enum.join(parts, ".")} is not on the allowlist — only pure stdlib " <>
            "(Enum, Map, String, Jason, ...) and Tools.* are available"
        )
    end
  end

  defp reject(reason), do: {:rejected, reason}

  # ── evaluation ───────────────────────────────────────────────────────

  defp run(ast, state, binding, timeout, max_output) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        # Make the caller's MCP state visible to the generated Tools.* functions.
        CodeExec.put_state(state)

        # Redirect stdout (group leader) to an in-memory StringIO so we can
        # capture and cap it.
        {:ok, io} = StringIO.open("")
        Process.group_leader(self(), io)

        result = eval_statements(top_level_statements(ast), binding, eval_env())

        {_in, out} = StringIO.contents(io)
        StringIO.close(io)
        send(parent, {ref, result, out})
      end)

    receive do
      {^ref, result, out} ->
        Task.shutdown(task, :brutal_kill)
        finalize(result, out, max_output)
    after
      timeout ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:timeout, timeout}}
    end
  end

  # A `:__block__` is what the parser produces for multiple top-level
  # statements (separated by newlines or `;`); a snippet that's a single
  # expression has no wrapping block at all.
  defp top_level_statements({:__block__, _meta, statements}), do: statements
  defp top_level_statements(ast), do: [ast]

  # Evaluate each top-level statement in turn, threading the binding AND env
  # forward (`Code.eval_quoted_with_env/4` is the documented shape for
  # exactly this loop-of-evals use case — plain `eval_quoted/3` would forget
  # any `require`/`import`/`alias` from an earlier statement). Stops at the
  # first raise, carrying the binding as of the last *successful* statement
  # so the caller can persist that partial progress instead of losing it.
  defp eval_statements(statements, binding, env) do
    count = length(statements)

    statements
    |> Enum.with_index(1)
    |> Enum.reduce_while({binding, env, nil}, fn {statement, index}, {binding, env, _value} ->
      try do
        {value, new_binding, new_env} = Code.eval_quoted_with_env(statement, binding, env)
        {:cont, {new_binding, new_env, value}}
      rescue
        e -> {:halt, {:raised, :error, e, __STACKTRACE__, binding, index, count}}
      catch
        kind, reason -> {:halt, {:raised, kind, reason, __STACKTRACE__, binding, index, count}}
      end
    end)
    |> case do
      {:raised, _, _, _, _, _, _} = raised -> raised
      {binding, _env, value} -> {:ok, value, binding}
    end
  end

  defp finalize({:ok, value, binding}, out, max_output) do
    {:ok, %{value: value, stdout: cap(out, max_output), binding: binding}}
  end

  defp finalize({:raised, kind, reason, trace, partial_binding, index, count}, out, max_output) do
    banner = Exception.format_banner(kind, reason)
    line = snippet_line(trace)

    {:error,
     {:exception,
      %{
        banner: cap(banner, max_output),
        line: line,
        stdout: cap(out, max_output),
        partial_binding: partial_binding,
        statement: index,
        statement_count: count
      }}}
  end

  # The first stack frame attributed to the snippet — its line is the offending
  # line of the model's code. Internal eval/Task frames are skipped.
  defp snippet_line(trace) do
    Enum.find_value(trace, fn
      {_mod, _fun, _arity, loc} ->
        if loc[:file] && to_string(loc[:file]) == @snippet_file, do: loc[:line]

      _ ->
        nil
    end)
  end

  defp cap(bin, max) when byte_size(bin) > max do
    binary_part(bin, 0, max) <> "\n…[truncated #{byte_size(bin) - max} bytes]"
  end

  defp cap(bin, _max), do: bin

  # A minimal eval env, built via `Code.env_for_eval/1` — the documented way
  # to seed a "loop of evals" (our sequential top-level statements are exactly
  # that; `eval_quoted_with_env/4` threads the env this produces from one
  # statement to the next). We deliberately do NOT auto-`import`/`alias`
  # anything beyond defaults — the allowlist check already gates module
  # access, and the generated `Tools` modules are referenced by their
  # fully-qualified name. The synthetic file name lets us recover the
  # snippet's own line numbers.
  defp eval_env do
    Code.env_for_eval(file: @snippet_file)
  end
end
