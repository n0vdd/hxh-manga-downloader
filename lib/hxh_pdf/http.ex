defmodule HxhPdf.Http do
  @moduledoc """
  HTTP client with flow-control gating, automatic retries, and exponential backoff.

  Every request passes through `HxhPdf.FlowControl` which acts as an adaptive
  permit semaphore — permits increase after sustained success and decrease on
  errors, keeping downstream pressure in check.

  Retry strategy:
  - Responses with status 429 or >= 500 are retried.
  - Transport errors (timeouts, connection resets, etc.) are retried.
  - 4xx responses (other than 429) are considered permanent failures.
  - Backoff is exponential (1s, 2s, 4s …) with random jitter up to 500ms.
  """

  @default_headers [
    {"user-agent", "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"},
    {"referer", "https://w19.read-hxh.com/"}
  ]

  @finch_name HxhPdf.Finch

  @doc """
  Starts the Finch connection pool used by all HTTP requests.
  """
  def start_pool do
    Finch.start_link(
      name: @finch_name,
      pools: %{default: [size: 30, count: 1, conn_opts: [transport_opts: [timeout: 10_000]]]}
    )
  end

  @doc """
  Performs a GET request with flow-control gating and retries.

  `req_opts` is a keyword list passed to `Req.get/1` — at minimum `[url: url]`.
  For streaming downloads, include `into: File.stream!(path)`.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def get(req_opts, max_retries \\ 3) do
    do_get(req_opts, max_retries, 0)
  end

  defp do_get(_req_opts, max_retries, attempt) when attempt > max_retries do
    {:error, :max_retries_exceeded}
  end

  defp do_get(req_opts, max_retries, attempt) do
    HxhPdf.FlowControl.acquire()

    result =
      Req.get(
        Keyword.merge(
          [headers: @default_headers, finch: @finch_name],
          Keyword.merge(req_opts,
            retry: false,
            receive_timeout: 30_000
          )
        )
      )

    outcome = classify_result(result)

    HxhPdf.FlowControl.release(if(outcome == :success, do: :ok, else: :error))

    case outcome do
      :success ->
        result

      :retriable when attempt < max_retries ->
        backoff = retry_backoff(attempt)
        Process.sleep(backoff)
        do_get(req_opts, max_retries, attempt + 1)

      _ ->
        result
    end
  end

  defp classify_result({:ok, %{status: status}}) when status in 200..399, do: :success
  defp classify_result({:ok, %{status: 429}}), do: :retriable
  defp classify_result({:ok, %{status: status}}) when status >= 500, do: :retriable
  defp classify_result({:ok, _}), do: :permanent
  defp classify_result({:error, _}), do: :retriable

  defp retry_backoff(attempt) do
    base = 1_000 * Integer.pow(2, attempt)
    jitter = :rand.uniform(500)
    base + jitter
  end
end
