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

  def list_pending_requests_for_session(session_id) do
    Repo.all(
      from r in FeedbackRequest,
        where: r.status == "pending" and r.session_id == ^session_id,
        order_by: [asc: r.inserted_at]
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

        if request.session_id do
          notify_runner(:notify_feedback_answered, request.session_id)
        end

      _ ->
        :ok
    end)
  end

  def cancel(id) do
    request = get_request!(id)

    request
    |> FeedbackRequest.changeset(%{status: "cancelled"})
    |> Repo.update()
    |> tap(fn
      {:ok, request} ->
        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "feedback:#{request.id}", {:feedback_cancelled, request})

        if request.session_id do
          notify_runner(:notify_feedback_answered, request.session_id)
        end

      _ ->
        :ok
    end)
  end

  # Route SessionRunner notifications to the correct node
  defp notify_runner(fun, session_id) do
    case OrcaHub.Cluster.find_session(session_id) do
      {runner_node, _session} ->
        OrcaHub.Cluster.rpc(runner_node, OrcaHub.SessionRunner, fun, [session_id])

      nil ->
        # Session not found — try local node as fallback
        apply(OrcaHub.SessionRunner, fun, [session_id])
    end
  end
end
