defmodule OrcaHub.Repo.Migrations.AddNodeFields do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :runner_node, :string
    end

    alter table(:projects) do
      add :node, :string
    end
  end
end
