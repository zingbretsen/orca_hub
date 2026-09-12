defmodule OrcaHub.Scheduler do
  @moduledoc """
  Quantum scheduler for firing scheduled (cron) triggers.
  """

  use Quantum, otp_app: :orca_hub

  require Logger

  alias OrcaHub.{TriggerExecutor, Triggers}

  def sync_triggers do
    # jobs/0 returns {name, %Quantum.Job{}} pairs (Quantum.JobBroadcaster's
    # internal job map, listed), not bare job structs.
    jobs() |> Enum.each(fn {name, _job} -> delete_job(name) end)

    Triggers.list_enabled_triggers()
    |> Enum.filter(& &1.cron_expression)
    |> Enum.each(fn trigger ->
      try do
        schedule_trigger(trigger)
      rescue
        e ->
          Logger.error(
            "sync_triggers: failed to schedule trigger #{trigger.id} (#{trigger.name}): " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
      end
    end)

    registered =
      jobs()
      |> Enum.map(fn {name, job} -> "#{name}@#{inspect(job.schedule)} (#{job.state})" end)

    Logger.info("sync_triggers: registered #{length(registered)} job(s): #{inspect(registered)}")
  end

  def schedule_trigger(trigger) do
    job =
      new_job()
      |> Quantum.Job.set_name(job_name(trigger.id))
      |> Quantum.Job.set_schedule(Crontab.CronExpression.Parser.parse!(trigger.cron_expression))
      |> Quantum.Job.set_task({TriggerExecutor, :execute, [trigger.id]})
      |> Quantum.Job.set_state(:active)

    add_job(job)
  end

  def unschedule_trigger(trigger_id) do
    delete_job(job_name(trigger_id))
  end

  defp job_name(trigger_id), do: :"trigger_#{trigger_id}"
end
