defmodule OrcaHub.Scheduler do
  use Quantum, otp_app: :orca_hub

  alias OrcaHub.{Triggers, TriggerExecutor}

  def sync_triggers do
    jobs() |> Enum.each(fn job -> delete_job(job.name) end)

    Triggers.list_enabled_triggers()
    |> Enum.filter(& &1.cron_expression)
    |> Enum.each(&schedule_trigger/1)
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
