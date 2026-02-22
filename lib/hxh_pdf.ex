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
  @default_chapters 4
  @default_images 6
  @finch_name HxhPdf.Finch

  @headers [
    {"user-agent", "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"},
    {"referer", "https://w19.read-hxh.com/"}
  ]

  @doc """
  Entry point for the escript.

  ## Options

    * `--from N` — first chapter to download (default: 1)
    * `--to N` — last chapter to download (default: #{@last_chapter})
    * `--no-optimize` — skip ImageMagick grayscale/strip/quality reduction
    * `--chapters N` — max concurrent chapters (default: #{@default_chapters})
    * `--images N` — max concurrent image downloads per chapter (default: #{@default_images})
  """
  def main(args \\ System.argv()) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          from: :integer,
          to: :integer,
          optimize: :boolean,
          chapters: :integer,
          images: :integer
        ]
      )

    from = Keyword.get(opts, :from, 1)
    to = Keyword.get(opts, :to, @last_chapter)
    optimize? = Keyword.get(opts, :optimize, true)
    max_chapters = Keyword.get(opts, :chapters, @default_chapters)
    max_images = Keyword.get(opts, :images, @default_images)

    Finch.start_link(
      name: @finch_name,
      pools: %{
        default: [
          size: max_chapters * max_images + max_chapters,
          count: System.schedulers_online(),
          conn_opts: [transport_opts: [timeout: 15_000]]
        ]
      }
    )

    File.mkdir_p!(@output_dir)
    cleanup_matching(System.tmp_dir!(), &String.starts_with?(&1, "hxh_ch"), &File.rm_rf/1)
    cleanup_matching(@output_dir, &String.ends_with?(&1, ".cbz.tmp"))

    chapters = Enum.to_list(from..to)
    {skipped, pending} = partition_chapters(chapters)

    opt_label = if optimize?, do: ", optimized", else: ""

    if skipped != [] do
      IO.puts("[SKIP] #{length(skipped)} chapters already exist")
    end

    total = length(pending)

    if pending == [] do
      IO.puts("Nothing to download.")
    else
      IO.puts(
        "Downloading #{total} chapters as cbz#{opt_label} (concurrency: #{max_chapters} chapters, #{max_images} images)"
      )

      start_time = System.monotonic_time(:millisecond)

      run_chapters(pending, optimize?, total, max_chapters, max_images)

      elapsed_s = (System.monotonic_time(:millisecond) - start_time) / 1_000
      IO.puts("\nElapsed: #{Float.round(elapsed_s, 1)}s | Done!")
    end
  end

  defp run_chapters(chapters, optimize?, total, max_chapters, max_images) do
    chapters
    |> Task.async_stream(
      fn chapter -> timed_process_chapter(chapter, optimize?, max_images) end,
      max_concurrency: max_chapters,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(0, fn result, done ->
      done = done + 1
      report_result(result, done, total)
      done
    end)
  end

  defp timed_process_chapter(chapter, optimize?, max_images) do
    start = System.monotonic_time(:millisecond)
    result = process_chapter(chapter, optimize?, max_images)
    elapsed = (System.monotonic_time(:millisecond) - start) / 1_000
    {result, elapsed}
  end

  defp report_result({:ok, {{:ok, chapter}, elapsed}}, done, total),
    do: IO.puts("[OK] Chapter #{chapter} in #{Float.round(elapsed, 1)}s (#{done}/#{total})")

  defp report_result({:ok, {{:error, chapter, reason}, elapsed}}, done, total),
    do:
      IO.puts(
        "[ERROR] Chapter #{chapter}: #{inspect(reason)} after #{Float.round(elapsed, 1)}s (#{done}/#{total})"
      )

  defp report_result({:exit, reason}, done, total),
    do: IO.puts("[EXIT] Task crashed: #{inspect(reason)} (#{done}/#{total})")

  defp partition_chapters(chapters) do
    {skipped, pending} = Enum.split_with(chapters, &File.exists?(output_path(&1)))
    {skipped, pending}
  end

  defp process_chapter(chapter, optimize?, max_images) do
    output_file = output_path(chapter)

    tmp_dir =
      Path.join(System.tmp_dir!(), "hxh_ch#{chapter}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    try do
      with {:ok, image_urls} <- scrape_chapter(chapter),
           :ok <- download_images(image_urls, tmp_dir, max_images),
           :ok <- maybe_optimize(tmp_dir, optimize?),
           :ok <- create_archive(tmp_dir, output_file) do
        {:ok, chapter}
      else
        {:error, reason} -> {:error, chapter, reason}
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp scrape_chapter(chapter) do
    url = chapter_url(chapter)

    with {:ok, %{status: 200, body: body}} <- http_get(url: url, max_retries: 3),
         {:ok, doc} <- Floki.parse_document(body) do
      case extract_image_urls(doc) do
        [] -> {:error, no_images_diagnostic(doc, chapter)}
        urls -> {:ok, urls}
      end
    else
      {:ok, %{status: status}} -> {:error, "HTTP #{status} for #{url}"}
      {:error, reason} -> {:error, reason}
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

  defp no_images_diagnostic(doc, chapter) do
    img_count = doc |> Floki.find("img") |> length()
    a_count = doc |> Floki.find("a") |> length()

    entry_html =
      case Floki.find(doc, ".entry-content") do
        [] -> "(no .entry-content found)"
        nodes -> nodes |> Floki.raw_html() |> String.slice(0, 500)
      end

    "no images found for chapter #{chapter} | <img>: #{img_count}, <a>: #{a_count} | entry-content preview: #{entry_html}"
  end

  defp download_images(urls, tmp_dir, max_images) do
    urls
    |> Enum.with_index(1)
    |> Task.async_stream(&download_one(&1, tmp_dir),
      max_concurrency: max_images,
      timeout: :infinity
    )
    |> Enum.reduce_while(:ok, fn
      {:exit, reason}, _acc -> {:halt, {:error, "download task crashed: #{inspect(reason)}"}}
      {:ok, :ok}, acc -> {:cont, acc}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
    end)
  end

  defp download_one({url, idx}, tmp_dir) do
    padded = idx |> Integer.to_string() |> String.pad_leading(3, "0")
    ext = url_extension(url)
    dest = Path.join(tmp_dir, "#{padded}#{ext}")
    download_image(url, dest)
  end

  defp download_image(url, dest) do
    case http_get(url: url, max_retries: 5) do
      {:ok, %{status: 200, body: body}} ->
        File.write!(dest, body)
        :ok

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} downloading #{url}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_get(opts) do
    {max_retries, opts} = Keyword.pop(opts, :max_retries, 3)

    [
      headers: @headers,
      finch: @finch_name,
      retry: :transient,
      max_retries: max_retries,
      receive_timeout: 30_000
    ]
    |> Keyword.merge(opts)
    |> Req.get()
  end

  defp maybe_optimize(_tmp_dir, false), do: :ok

  defp maybe_optimize(tmp_dir, true) do
    files =
      tmp_dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.map(&Path.join(tmp_dir, &1))

    args = ["mogrify", "-colorspace", "Gray", "-strip", "-quality", "60"] ++ files

    case System.cmd("magick", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "magick mogrify failed: #{output}"}
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

  defp chapter_url(407), do: "#{@base_url}/hunter-x-hunter-chapter-407-2/"
  defp chapter_url(n), do: "#{@base_url}/hunter-x-hunter-chapter-#{n}/"

  defp output_path(chapter) do
    padded = chapter |> Integer.to_string() |> String.pad_leading(3, "0")
    Path.join(@output_dir, "Hunter_x_Hunter_#{padded}.cbz")
  end

  defp url_extension(url) do
    uri = URI.parse(url)

    case Path.extname(uri.path || "") do
      "" -> ".jpg"
      ext -> ext
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
