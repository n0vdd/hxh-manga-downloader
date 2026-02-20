defmodule HxhPdf.RateLimiter do
  @moduledoc false

  use GenServer

  @max_requests 5
  @window_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def acquire do
    GenServer.call(__MODULE__, :acquire, :infinity)
  end

  @impl true
  def init(_opts) do
    {:ok, %{timestamps: :queue.new(), count: 0}}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    now = System.monotonic_time(:millisecond)
    {timestamps, count} = prune_old(state.timestamps, state.count, now)

    if count < @max_requests do
      timestamps = :queue.in(now, timestamps)
      {:reply, :ok, %{timestamps: timestamps, count: count + 1}}
    else
      {{:value, oldest}, _} = :queue.out(timestamps)
      sleep_ms = max(oldest + @window_ms - now, 1)
      Process.sleep(sleep_ms)

      now = System.monotonic_time(:millisecond)
      {timestamps, count} = prune_old(timestamps, count, now)
      timestamps = :queue.in(now, timestamps)
      {:reply, :ok, %{timestamps: timestamps, count: count + 1}}
    end
  end

  defp prune_old(queue, count, now) do
    case :queue.peek(queue) do
      {:value, ts} when now - ts >= @window_ms ->
        {_, queue} = :queue.out(queue)
        prune_old(queue, count - 1, now)

      _ ->
        {queue, count}
    end
  end
end
