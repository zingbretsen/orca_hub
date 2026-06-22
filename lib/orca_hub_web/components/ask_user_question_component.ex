defmodule OrcaHubWeb.AskUserQuestionComponent do
  @moduledoc """
  Renders Claude's built-in `AskUserQuestion` tool as an interactive wizard —
  one page per question, with Prev/Next navigation and a final Submit.

  Used in two places:

    * `:modal` variant — overlaid on the session page (`SessionLive.Show`)
    * `:inline` variant — a card in the queue (`QueueLive`)

  The component is purely presentational. The parent LiveView owns the page
  index + selection state and handles these events (all carry `phx-value-id`
  = the session id, plus `phx-value-q` = the question index where relevant):

    * `"aq_select"`  — `id`, `q`, `label`, `multi` ("true"/"false")
    * `"aq_prev"`    — `id`
    * `"aq_next"`    — `id`
    * `"aq_submit"`  — `id`
    * `"aq_cancel"`  — `id` (modal only; closes without sending)
  """
  use Phoenix.Component

  import OrcaHubWeb.CoreComponents, only: [icon: 1]

  attr :session_id, :string, required: true
  attr :questions, :list, required: true
  attr :page, :integer, default: 0
  attr :selections, :map, default: %{}
  attr :variant, :atom, default: :inline, values: [:inline, :modal]
  attr :title, :string, default: nil

  def ask_user_question(assigns) do
    assigns =
      assigns
      |> assign(:total, length(assigns.questions))
      |> assign(:question, Enum.at(assigns.questions, assigns.page))

    ~H"""
    <div class={[
      @variant == :modal && "modal modal-open",
      @variant == :inline && "w-full"
    ]}>
      <div class={[
        @variant == :modal && "modal-box max-w-xl",
        @variant == :inline &&
          "card bg-base-100 border-2 border-info/50 shadow-sm w-full"
      ]}>
        <div class={[@variant == :inline && "card-body p-4 gap-3"]}>
          <div class="flex items-center gap-2 text-info">
            <.icon name="hero-question-mark-circle" class="size-5" />
            <span class="font-semibold">{@title || "Claude is asking a question"}</span>
            <span :if={@total > 1} class="text-xs text-base-content/50 ml-auto">
              Question {@page + 1} of {@total}
            </span>
          </div>

          <div :if={@question}>
            <div
              :if={@question["header"] not in [nil, ""]}
              class="text-xs uppercase tracking-wide text-base-content/50"
            >
              {@question["header"]}
            </div>
            <div class="font-medium mt-0.5">{@question["question"]}</div>
            <div :if={@question["multiSelect"]} class="text-xs text-base-content/50 mt-0.5">
              Select all that apply
            </div>

            <div class="flex flex-col gap-2 mt-3">
              <button
                :for={opt <- @question["options"]}
                type="button"
                phx-click="aq_select"
                phx-value-id={@session_id}
                phx-value-q={@page}
                phx-value-label={opt["label"]}
                phx-value-multi={to_string(@question["multiSelect"])}
                class={[
                  "text-left rounded-lg border p-3 transition-colors",
                  selected?(@selections, @page, opt["label"]) &&
                    "border-info bg-info/10",
                  !selected?(@selections, @page, opt["label"]) &&
                    "border-base-300 hover:border-base-content/30 hover:bg-base-200"
                ]}
              >
                <div class="flex items-start gap-2">
                  <.icon
                    name={
                      if @question["multiSelect"],
                        do: selection_icon(@selections, @page, opt["label"], :multi),
                        else: selection_icon(@selections, @page, opt["label"], :single)
                    }
                    class={[
                      "size-5 shrink-0 mt-0.5",
                      selected?(@selections, @page, opt["label"]) && "text-info"
                    ]}
                  />
                  <div class="min-w-0">
                    <div class="font-medium">{opt["label"]}</div>
                    <div
                      :if={opt["description"] not in [nil, ""]}
                      class="text-sm text-base-content/60"
                    >
                      {opt["description"]}
                    </div>
                  </div>
                </div>
              </button>
            </div>
          </div>

          <div class="flex items-center justify-between gap-2 mt-2">
            <button
              :if={@variant == :modal}
              type="button"
              phx-click="aq_cancel"
              phx-value-id={@session_id}
              class="btn btn-ghost btn-sm"
            >
              Cancel
            </button>
            <span :if={@variant == :inline}></span>

            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="aq_prev"
                phx-value-id={@session_id}
                disabled={@page == 0}
                class="btn btn-sm btn-ghost"
              >
                <.icon name="hero-chevron-left-micro" class="size-4" /> Prev
              </button>

              <button
                :if={@page < @total - 1}
                type="button"
                phx-click="aq_next"
                phx-value-id={@session_id}
                disabled={!answered?(@selections, @page)}
                class="btn btn-sm btn-primary"
              >
                Next <.icon name="hero-chevron-right-micro" class="size-4" />
              </button>

              <button
                :if={@page >= @total - 1}
                type="button"
                phx-click="aq_submit"
                phx-value-id={@session_id}
                disabled={!all_answered?(@selections, @total)}
                class="btn btn-sm btn-success"
              >
                <.icon name="hero-paper-airplane-micro" class="size-4" /> Submit answers
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp selected?(selections, page, label) do
    label in Map.get(selections, page, [])
  end

  defp answered?(selections, page) do
    Map.get(selections, page, []) != []
  end

  defp all_answered?(selections, total) do
    Enum.all?(0..(total - 1)//1, &answered?(selections, &1))
  end

  defp selection_icon(selections, page, label, :single) do
    if selected?(selections, page, label), do: "hero-check-circle-solid", else: "hero-stop-circle"
  end

  defp selection_icon(selections, page, label, :multi) do
    if selected?(selections, page, label),
      do: "hero-check-circle-solid",
      else: "hero-square-2-stack"
  end
end
