defmodule HxhPdf do
  @moduledoc """
  CLI escript that scrapes Hunter x Hunter manga chapters from w19.read-hxh.com
  and packages them as CBZ archives.

  Pipeline per chapter: check if CBZ exists (skip) → scrape image URLs from HTML
  → download images to temp dir → optionally optimize with ImageMagick → create
  CBZ via Erlang `:zip` → cleanup temp dir.

  Output goes to `./output/` as `Hunter_x_Hunter_XXX.cbz`.
  """

  @base_url "https://w19.read-hxh.com/manga"
  @output_dir "output"
  @last_chapter 412
  @max_chapter_concurrency 3
  @max_image_concurrency 8
  @scrape_max_retries 3
  @image_max_retries 5

  @doc """
  Entry point for the escript.

  ## Options

    * `--from N` — first chapter to download (default: 1)
    * `--to N` — last chapter to download (default: #{@last_chapter})
    * `--no-optimize` — skip ImageMagick grayscale/strip/quality reduction
  """
  def main(args \\ System.argv()) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [from: :integer, to: :integer, no_optimize: :boolean]
      )

    from = Keyword.get(opts, :from, 1)
    to = Keyword.get(opts, :to, @last_chapter)
    optimize? = not Keyword.get(opts, :no_optimize, false)

    HxhPdf.Shutdown.init()

    System.trap_signal(:sigterm, fn ->
      IO.puts("\n[SHUTDOWN] SIGTERM received, finishing in-flight chapters...")
      HxhPdf.Shutdown.request()
    end)

    HxhPdf.FlowControl.start_link([])
    HxhPdf.Http.start_pool()

    File.mkdir_p!(@output_dir)
    cleanup_matching(System.tmp_dir!(), &String.starts_with?(&1, "hxh_ch"), &File.rm_rf/1)
    cleanup_matching(@output_dir, &String.ends_with?(&1, ".cbz.tmp"))

    chapters = Enum.to_list(from..to)
    total = length(chapters)

    opt_label = if optimize?, do: ", optimized", else: ""
    IO.puts("Downloading chapters #{from}-#{to} as cbz (#{total} chapters#{opt_label})")

    start_time = System.monotonic_time(:millisecond)

    run_chapters(chapters, optimize?, @max_chapter_concurrency)

    elapsed_s = (System.monotonic_time(:millisecond) - start_time) / 1_000
    print_summary(elapsed_s)
  end

  defp run_chapters(chapters, optimize?, max_concurrency) do
    run_chapters(chapters, optimize?, max_concurrency, %{})
  end

  defp run_chapters([], _optimize?, _max_concurrency, in_flight) when map_size(in_flight) == 0 do
    :ok
  end

  defp run_chapters(remaining, optimize?, max_concurrency, in_flight) do
    {to_launch, remaining} =
      if HxhPdf.Shutdown.requested?() do
        {[], remaining}
      else
        slots = max_concurrency - map_size(in_flight)
        Enum.split(remaining, slots)
      end

    new_in_flight =
      Enum.reduce(to_launch, in_flight, fn chapter, acc ->
        task = Task.async(fn -> process_chapter(chapter, optimize?) end)
        Map.put(acc, task.ref, task)
      end)

    if map_size(new_in_flight) == 0 do
      if remaining != [] do
        skipped = length(remaining)
        IO.puts("[SHUTDOWN] Skipped #{skipped} remaining chapter(s)")
      end

      :ok
    else
      receive do
        {ref, result} when is_map_key(new_in_flight, ref) ->
          Process.demonitor(ref, [:flush])
          report_result(result)
          run_chapters(remaining, optimize?, max_concurrency, Map.delete(new_in_flight, ref))

        {:DOWN, ref, :process, _pid, reason} when is_map_key(new_in_flight, ref) ->
          IO.puts("[EXIT] Task crashed: #{inspect(reason)}")
          run_chapters(remaining, optimize?, max_concurrency, Map.delete(new_in_flight, ref))
      end
    end
  end

  defp report_result({:ok, chapter}), do: IO.puts("[OK] Chapter #{chapter}")
  defp report_result({:skip, chapter}), do: IO.puts("[SKIP] Chapter #{chapter} (already exists)")

  defp report_result({:error, chapter, reason}),
    do: IO.puts("[ERROR] Chapter #{chapter}: #{inspect(reason)}")

  defp print_summary(elapsed_s) do
    stats = HxhPdf.FlowControl.get_stats()

    throughput =
      if elapsed_s > 0,
        do: Float.round(stats.total_requests / elapsed_s, 1),
        else: 0.0

    IO.puts("""

    --- Summary ---
    Total requests: #{stats.total_requests} (#{stats.total_successes} ok, #{stats.total_errors} errors)
    Permit range: #{stats.min_permits_seen}-#{stats.peak_permits} (final: #{stats.current_permits})
    Adjustments: +#{stats.permit_increases} / -#{stats.permit_decreases}
    Waits: #{stats.total_waits}
    Elapsed: #{Float.round(elapsed_s, 1)}s | Throughput: #{throughput} req/s
    Done!\
    """)
  end

  defp process_chapter(chapter, optimize?) do
    output_file = output_path(chapter)

    if File.exists?(output_file) do
      {:skip, chapter}
    else
      tmp_dir =
        Path.join(System.tmp_dir!(), "hxh_ch#{chapter}_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        with {:ok, image_urls} <- scrape_chapter(chapter),
             :ok <- download_images(image_urls, tmp_dir, optimize?),
             :ok <- create_archive(tmp_dir, output_file) do
          {:ok, chapter}
        else
          {:error, reason} -> {:error, chapter, reason}
        end
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  defp chapter_url(407), do: "#{@base_url}/hunter-x-hunter-chapter-407-2/"
  defp chapter_url(n), do: "#{@base_url}/hunter-x-hunter-chapter-#{n}/"

  defp output_path(chapter) do
    padded = chapter |> Integer.to_string() |> String.pad_leading(3, "0")
    Path.join(@output_dir, "Hunter_x_Hunter_#{padded}.cbz")
  end

  defp scrape_chapter(chapter) do
    url = chapter_url(chapter)

    with {:ok, %{status: 200, body: body}} <- HxhPdf.Http.get([url: url], @scrape_max_retries),
         {:ok, doc} <- Floki.parse_document(body) do
      case extract_image_urls(doc) do
        [] -> {:error, "no images found for chapter #{chapter}"}
        urls -> {:ok, urls}
      end
    else
      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} for #{url}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_image_urls(doc) do
    case doc |> Floki.find(".entry-content a[href*='blogger']") |> Floki.attribute("href") do
      [] ->
        doc
        |> Floki.find(".entry-content img[src*='laiond']")
        |> Floki.attribute("src")
        |> Enum.uniq()

      urls ->
        Enum.uniq(urls)
    end
  end

  defp download_images(urls, tmp_dir, optimize?) do
    urls
    |> Enum.with_index(1)
    |> Task.async_stream(&download_one(&1, tmp_dir, optimize?),
      max_concurrency: @max_image_concurrency,
      timeout: :infinity
    )
    |> Enum.to_list()
    |> check_results()
  end

  defp download_one({url, idx}, tmp_dir, optimize?) do
    padded = idx |> Integer.to_string() |> String.pad_leading(3, "0")
    ext = url_extension(url)
    dest = Path.join(tmp_dir, "#{padded}#{ext}")

    with :ok <- download_image(url, dest) do
      if optimize?, do: optimize_image(dest), else: :ok
    end
  end

  defp check_results(results) do
    Enum.reduce_while(results, :ok, fn
      {:exit, reason}, _acc -> {:halt, {:error, "download task crashed: #{inspect(reason)}"}}
      {:ok, :ok}, acc -> {:cont, acc}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
    end)
  end

  defp url_extension(url) do
    uri = URI.parse(url)

    case Path.extname(uri.path || "") do
      "" -> ".jpg"
      ext -> ext
    end
  end

  defp download_image(url, dest) do
    case HxhPdf.Http.get([url: url, into: File.stream!(dest)], @image_max_retries) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "HTTP #{status} downloading #{url}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optimize_image(path) do
    case System.cmd("magick", [path, "-colorspace", "Gray", "-strip", "-quality", "60", path],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, "magick optimize failed: #{output}"}
    end
  end

  defp create_archive(tmp_dir, output_file) do
    tmp_output = output_file <> ".tmp"

    files =
      tmp_dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.map(fn name ->
        {String.to_charlist(name), File.read!(Path.join(tmp_dir, name))}
      end)

    case :zip.create(String.to_charlist(tmp_output), files) do
      {:ok, _} ->
        File.rename!(tmp_output, output_file)
        :ok

      {:error, reason} ->
        File.rm(tmp_output)
        {:error, "zip failed: #{inspect(reason)}"}
    end
  end

  defp cleanup_matching(dir, match_fn, remove_fn \\ &File.rm/1) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(match_fn)
        |> Enum.each(&remove_fn.(Path.join(dir, &1)))

      _ ->
        :ok
    end
  end
end
