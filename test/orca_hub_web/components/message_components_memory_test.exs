defmodule OrcaHubWeb.MessageComponentsMemoryTest do
  @moduledoc """
  Rendering checks for the `memory_injected` system event — collapsed by
  default, with an optional link to the memory-service dashboard — and for
  stripping the leading `<orca-memory>` block back out of a user bubble's
  display text. Kept in its own `async: false` file (instead of
  `message_components_test.exs`, which is `async: true`) since these tests
  mutate the global `:memory_service_public_url` app env.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias OrcaHubWeb.MessageComponents

  setup do
    on_exit(fn -> Application.delete_env(:orca_hub, :memory_service_public_url) end)
    :ok
  end

  defp memory_injected_event(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "system",
        "subtype" => "memory_injected",
        "memory_ids" => ["mem-1", "mem-2"],
        "hooks" => ["first hook", "second hook"],
        "pinned_count" => 1,
        "recalled_count" => 1,
        "block" => "**fact:**\n- [fact] first hook — some detail\n- [fact] second hook — more"
      },
      overrides
    )
  end

  defp memories_event(memories, overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "system",
        "subtype" => "memory_injected",
        "memory_ids" => Enum.map(memories, & &1["id"]),
        "memories" => memories,
        "pinned_count" => 0,
        "recalled_count" => length(memories)
      },
      overrides
    )
  end

  describe "memory_injected system event" do
    test "renders a collapsed one-line summary with the total/pinned/recalled counts" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [memory_injected_event()],
          session_node: nil
        })

      assert html =~ "2 memories loaded (1 pinned, 1 recalled)"
      assert html =~ "<details>"
      assert html =~ "<summary"
      # Hooks are inside the (collapsed-by-default) details body.
      assert html =~ "first hook"
      assert html =~ "second hook"
    end

    test "singular noun for exactly one memory" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [
            memory_injected_event(%{
              "memory_ids" => ["mem-1"],
              "hooks" => ["only hook"],
              "pinned_count" => 0,
              "recalled_count" => 1
            })
          ],
          session_node: nil
        })

      assert html =~ "1 memory loaded (0 pinned, 1 recalled)"
      refute html =~ "1 memories"
    end

    test "hooks render as plain text (no link) when no public URL is configured" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [memory_injected_event()],
          session_node: nil
        })

      refute html =~ "<a "
    end

    test "hooks link to <base>/memories/<id> when a public URL is configured" do
      Application.put_env(:orca_hub, :memory_service_public_url, "https://memory.example.com")

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [memory_injected_event()],
          session_node: nil
        })

      assert html =~ ~s(href="https://memory.example.com/memories/mem-1")
      assert html =~ ~s(href="https://memory.example.com/memories/mem-2")
    end

    test "offers a nested toggle to show the raw injected block" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [memory_injected_event()],
          session_node: nil
        })

      assert html =~ "Show raw injected block"
      assert html =~ "some detail"
    end

    test "omits the raw-block toggle when the event carries no block" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [memory_injected_event(%{"block" => nil})],
          session_node: nil
        })

      refute html =~ "Show raw injected block"
    end
  end

  describe "memory_injected — \"memories\" array (memory-service c932074): kind + review badges" do
    test "renders each row's kind as a badge" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [
            memories_event([
              %{"id" => "mem-1", "hook" => "first hook", "kind" => "fact"},
              %{"id" => "mem-2", "hook" => "second hook", "kind" => "preference"}
            ])
          ],
          session_node: nil
        })

      assert html =~ "fact"
      assert html =~ "preference"
    end

    test "shows a muted pending-review badge for a pending memory" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [
            memories_event([
              %{
                "id" => "mem-1",
                "hook" => "unreviewed hook",
                "kind" => "fact",
                "review_status" => "pending"
              }
            ])
          ],
          session_node: nil
        })

      assert html =~ "pending review"
    end

    test "shows no review badge for an approved memory" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [
            memories_event([
              %{
                "id" => "mem-1",
                "hook" => "reviewed hook",
                "kind" => "fact",
                "review_status" => "approved"
              }
            ])
          ],
          session_node: nil
        })

      refute html =~ "pending review"
    end

    test "a rejected review_status shows no review badge either" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [
            memories_event([
              %{
                "id" => "mem-1",
                "hook" => "unreviewed content",
                "kind" => "fact",
                "review_status" => "rejected"
              }
            ])
          ],
          session_node: nil
        })

      refute html =~ "pending review"
      refute html =~ "badge-ghost"
    end

    test "an older event (no \"memories\" key) still renders from \"hooks\", no kind/badge" do
      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [memory_injected_event()],
          session_node: nil
        })

      refute html =~ "pending review"
    end
  end

  describe "user bubble — leading <orca-memory> block is stripped for display" do
    test "a leading orca-memory block is hidden from the user bubble" do
      msg = %{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "text",
              "text" => "<orca-memory>\n- a fact\n</orca-memory>\n\nwhat's the weather"
            }
          ]
        }
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{messages: [msg], session_node: nil})

      assert html =~ "what&#39;s the weather"
      refute html =~ "orca-memory"
      refute html =~ "a fact"
    end

    test "a message with no leading orca-memory block is unaffected" do
      msg = %{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => "plain message, nothing to strip"}]
        }
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{messages: [msg], session_node: nil})

      assert html =~ "plain message, nothing to strip"
    end

    test "an orca-memory-looking string that does NOT start the message is left alone" do
      msg = %{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "text",
              "text" => "please explain <orca-memory>\ntags</orca-memory>\n\nto me"
            }
          ]
        }
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{messages: [msg], session_node: nil})

      assert html =~ "please explain"
    end
  end
end
