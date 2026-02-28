defmodule OrcaHub.Feedback do
  import Ecto.Query
  alias OrcaHub.{Repo, Feedback.FeedbackRequest}

  def list_pending_requests do
    Repo.all(
      from r in FeedbackRequest,
        where: r.status == "pending",
        order_by: [asc: r.inserted_at],
        preload: [:session]
    )
  end

  def get_request!(id), do: Repo.get!(FeedbackRequest, id)

  def create_request(attrs) do
    %FeedbackRequest{}
    |> FeedbackRequest.changeset(attrs)
    |> Repo.insert()
  end

  def respond(id, response) do
    request = get_request!(id)

    request
    |> FeedbackRequest.changeset(%{response: response, status: "responded"})
    |> Repo.update()
    |> tap(fn
      {:ok, request} ->
        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "feedback:#{request.id}", {:feedback_response, request})

      _ ->
        :ok
    end)
  end
end
