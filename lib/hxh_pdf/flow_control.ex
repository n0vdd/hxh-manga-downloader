defmodule HxhPdf.FlowControl do
  use GenServer

  @initial_permits 10
  @min_permits 3
  @max_permits 30
  @increase_after 20
  @cooldown_ms 3_000
  @log_interval_ms 30_000

  @moduledoc """
  Adaptive permit semaphore controlling HTTP request concurrency.

  Works like a token bucket with dynamic sizing: callers `acquire/0` a permit
  before making a request and `release/1` it after, reporting `:ok` or `:error`.

  **Increase rule:** after #{@increase_after} consecutive successes, add one
  permit (up to #{@max_permits}).

  **Decrease rule:** on error, cut permits by 20% (min #{@min_permits}), with
  a #{@cooldown_ms}ms cooldown between decreases to avoid over-correction.

  Callers that arrive when all permits are in use are queued and unblocked
  FIFO as permits free up.
  """

  @stats_keys [
    :in_flight,
    :total_requests,
    :total_successes,
    :total_errors,
    :total_waits,
    :permit_increases,
    :permit_decreases,
    :peak_permits,
    :min_permits_seen
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def acquire do
    GenServer.call(__MODULE__, :acquire, :infinity)
  end

  def release(result) do
    GenServer.cast(__MODULE__, {:release, result})
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :periodic_log, @log_interval_ms)

    {:ok,
     %{
       max: @initial_permits,
       in_flight: 0,
       waiters: :queue.new(),
       streak: 0,
       last_decrease: System.monotonic_time(:millisecond) - @cooldown_ms - 1,
       total_requests: 0,
       total_successes: 0,
       total_errors: 0,
       total_waits: 0,
       permit_increases: 0,
       permit_decreases: 0,
       peak_permits: @initial_permits,
       min_permits_seen: @initial_permits
     }}
  end

  @impl true
  def handle_call(:acquire, _from, %{in_flight: in_flight, max: max} = state)
      when in_flight < max do
    {:reply, :ok, %{state | in_flight: in_flight + 1}}
  end

  def handle_call(:acquire, from, state) do
    {:noreply,
     %{state | waiters: :queue.in(from, state.waiters), total_waits: state.total_waits + 1}}
  end

  def handle_call(:get_stats, _from, state) do
    stats =
      state
      |> Map.take(@stats_keys)
      |> Map.put(:current_permits, state.max)

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:release, result}, state) do
    state = %{state | in_flight: state.in_flight - 1, total_requests: state.total_requests + 1}

    state =
      case result do
        :ok -> %{state | total_successes: state.total_successes + 1}
        :error -> %{state | total_errors: state.total_errors + 1}
      end

    state = adjust(result, state)
    state = drain_waiters(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_log, state) do
    IO.puts(
      "[FlowControl] permits=#{state.max} in_flight=#{state.in_flight} ok=#{state.total_successes} err=#{state.total_errors}"
    )

    Process.send_after(self(), :periodic_log, @log_interval_ms)
    {:noreply, state}
  end

  defp adjust(:ok, state) do
    new_streak = state.streak + 1

    if new_streak >= @increase_after and state.max < @max_permits do
      new_max = state.max + 1

      %{
        state
        | max: new_max,
          streak: 0,
          permit_increases: state.permit_increases + 1,
          peak_permits: max(state.peak_permits, new_max)
      }
    else
      %{state | streak: new_streak}
    end
  end

  defp adjust(:error, state) do
    now = System.monotonic_time(:millisecond)

    if now - state.last_decrease > @cooldown_ms do
      reduction = max(div(state.max, 5), 1)
      new_max = max(state.max - reduction, @min_permits)

      %{
        state
        | max: new_max,
          streak: 0,
          last_decrease: now,
          permit_decreases: state.permit_decreases + 1,
          min_permits_seen: min(state.min_permits_seen, new_max)
      }
    else
      %{state | streak: 0}
    end
  end

  defp drain_waiters(%{in_flight: in_flight, max: max, waiters: waiters} = state)
       when in_flight < max do
    case :queue.out(waiters) do
      {{:value, from}, rest} ->
        GenServer.reply(from, :ok)
        drain_waiters(%{state | in_flight: in_flight + 1, waiters: rest})

      {:empty, _} ->
        state
    end
  end

  defp drain_waiters(state), do: state
end
