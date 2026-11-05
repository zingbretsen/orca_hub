defmodule OrcaHubWeb.AssetBundlesTest do
  @moduledoc """
  Runs the real esbuild profiles from `config/config.exs` into a temp dir and
  checks what they produce against what the root layout links.

  Two regressions this guards:

    * The root layout linked `/assets/vendor/xterm.css`, which no build step
      produced. Prod only had it because a stale hand-copied file rode into
      the Docker build context. Every `~p"/assets/..."` path in the root
      layout must now be an output of a configured build profile.
    * xterm was about half of app.js, which every page loads. It now lives in
      the lazily loaded `orca_hub_lazy` bundle, and app.js must not pull it
      back in.

  Needs `assets/node_modules` (`npm --prefix assets ci`) and the esbuild
  binary (`mix assets.setup`), like `mix assets.build` does.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @root_layout Path.expand(
                 "../../lib/orca_hub_web/components/layouts/root.html.heex",
                 __DIR__
               )

  setup do
    dir = Path.join(System.tmp_dir!(), "asset-bundles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Builds `profile` into `dir`, overriding only its --outdir, and returns the
  # emitted files as priv/static-relative paths (where the real build puts
  # them) mapped to their bytes in `dir`, plus the esbuild metafile.
  defp build!(profile, dir) do
    out = Path.join(dir, Atom.to_string(profile))
    meta = Path.join(dir, "#{profile}.meta.json")

    log =
      capture_io(fn ->
        status =
          Esbuild.run(profile, ["--outdir=#{out}", "--metafile=#{meta}", "--log-level=warning"])

        send(self(), {:esbuild_status, status})
      end)

    assert_received {:esbuild_status, 0}, "esbuild #{profile} failed:\n#{log}"

    static_prefix =
      Application.fetch_env!(:esbuild, profile)[:args]
      |> Enum.find_value(fn arg ->
        case arg do
          "--outdir=../priv/static/" <> rel -> rel
          _ -> nil
        end
      end)

    files =
      out
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Map.new(fn path ->
        {Path.join(static_prefix, Path.relative_to(path, out)), File.read!(path)}
      end)

    {files, meta |> File.read!() |> Jason.decode!()}
  end

  defp tailwind_outputs do
    Application.fetch_env!(:tailwind, :orca_hub)[:args]
    |> Enum.flat_map(fn
      "--output=priv/static/" <> rel -> [rel]
      _ -> []
    end)
  end

  defp root_layout_asset_paths do
    ~r{~p"/(assets/[^"]+)"}
    |> Regex.scan(File.read!(@root_layout), capture: :all_but_first)
    |> List.flatten()
  end

  defp bundled_inputs(meta, output_suffix) do
    {_, output} =
      Enum.find(meta["outputs"], fn {path, _} -> String.ends_with?(path, output_suffix) end)

    Map.keys(output["inputs"])
  end

  test "every asset the root layout links is produced by a build profile", %{dir: dir} do
    {app, _} = build!(:orca_hub, dir)
    {lazy, _} = build!(:orca_hub_lazy, dir)
    built = MapSet.new(Map.keys(app) ++ Map.keys(lazy) ++ tailwind_outputs())

    linked = root_layout_asset_paths()
    assert "assets/js/app.js" in linked

    for path <- linked do
      assert path in built,
             "the root layout links /#{path}, but no build profile produces it " <>
               "(built: #{inspect(Enum.sort(built))})"
    end
  end

  test "the terminal bundle carries xterm and its stylesheet", %{dir: dir} do
    {lazy, meta} = build!(:orca_hub_lazy, dir)

    assert lazy["assets/js/lazy/terminal.css"] =~ ".xterm-helper-textarea"
    assert Enum.any?(bundled_inputs(meta, "/terminal.js"), &(&1 =~ "node_modules/@xterm/xterm/"))
  end

  test "the mermaid bundle is split per diagram type", %{dir: dir} do
    {lazy, meta} = build!(:orca_hub_lazy, dir)

    assert Map.has_key?(lazy, "assets/js/lazy/mermaid.js")

    assert Enum.any?(
             Map.keys(meta["inputs"]),
             &(&1 =~ "node_modules/mermaid/dist/mermaid.core.mjs")
           )

    # Each diagram type is its own chunk, fetched only when a page draws one.
    assert Enum.any?(Map.keys(lazy), &(&1 =~ ~r{^assets/js/lazy/chunks/flowDiagram-.*\.js$}))
    assert Enum.any?(Map.keys(lazy), &(&1 =~ ~r{^assets/js/lazy/chunks/sequenceDiagram-.*\.js$}))
  end

  test "app.js, loaded on every page, bundles neither xterm nor mermaid", %{dir: dir} do
    {app, meta} = build!(:orca_hub, dir)

    assert Map.has_key?(app, "assets/js/app.js")
    inputs = bundled_inputs(meta, "/app.js")
    assert Enum.any?(inputs, &(&1 =~ "js/terminal_hook.js"))
    assert Enum.any?(inputs, &(&1 =~ "js/mermaid_blocks.js"))
    assert Enum.filter(inputs, &(&1 =~ "node_modules/@xterm/")) == []
    assert Enum.filter(inputs, &(&1 =~ "node_modules/mermaid/")) == []
  end
end
