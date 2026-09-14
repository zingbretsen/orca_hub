defmodule OrcaHub.Repo.Migrations.AddIssuesFulltextSearch do
  use Ecto.Migration

  # The LEXICAL leg of hybrid issue search (OrcaHub.Issues.Search) — the half
  # that still works when the embedding endpoint is down, which is the normal
  # state in the test suite and a survivable one in prod.
  #
  # A GENERATED ... STORED column rather than a trigger-maintained one: every
  # expression below is immutable (note the EXPLICIT 'english' regconfig —
  # to_tsvector/1 depends on default_text_search_config and is only STABLE, so
  # Postgres would reject it here), so Postgres maintains the vector itself on
  # every insert/update with no application code to forget.
  #
  # Weights encode "where a hit counts for more", which ts_rank/2 then honours:
  #   A title       — the single most load-bearing field
  #   B description — the body of the report
  #   C premise/resolution — narrative, high signal but longer
  #   D notes       — append-only running log, noisiest of the set
  #
  # `plan` and `approaches_tried` are deliberately NOT indexed here even
  # though OrcaHub.Issues.IssueChunk.indexable_fields/0 embeds them: `plan` is
  # rewritten in place as understanding develops and `approaches_tried` is a
  # dead-end log, so lexical hits in either mostly add noise to a keyword
  # search. The semantic leg still covers both.

  @tsv_expression """
  setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
  setweight(to_tsvector('english', coalesce(description, '')), 'B') ||
  setweight(to_tsvector('english', coalesce(premise, '')), 'C') ||
  setweight(to_tsvector('english', coalesce(resolution, '')), 'C') ||
  setweight(to_tsvector('english', coalesce(notes, '')), 'D')
  """

  def up do
    execute("""
    ALTER TABLE issues
      ADD COLUMN search_tsv tsvector
      GENERATED ALWAYS AS (#{@tsv_expression}) STORED
    """)

    execute("CREATE INDEX issues_search_tsv_idx ON issues USING GIN (search_tsv)")
  end

  def down do
    execute("DROP INDEX IF EXISTS issues_search_tsv_idx")
    execute("ALTER TABLE issues DROP COLUMN IF EXISTS search_tsv")
  end
end
