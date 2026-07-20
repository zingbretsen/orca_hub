defmodule OrcaHub.Repo.Migrations.AddCommitTrailerToProjects do
  use Ecto.Migration

  # Whether sessions under this project are instructed (via the backend
  # system prompt, see SharedPrompts.commit_trailer_prompt/1) to append the
  # OrcaHub-Session git trailer to their commits. Defaults true to preserve
  # existing behavior.
  def change do
    alter table(:projects) do
      add :commit_trailer, :boolean, null: false, default: true
    end
  end
end
