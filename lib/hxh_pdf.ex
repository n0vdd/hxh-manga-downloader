defmodule HxhPdf do
  @moduledoc """
  CLI release that scrapes Hunter x Hunter manga chapters from w19.read-hxh.com
  and packages them as CBZ archives.

  Pipeline per chapter: check if CBZ exists (skip) → scrape image URLs from HTML
  → download images to temp dir → create CBZ via Erlang `:zip` → cleanup temp dir.

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
  Entry point for the release CLI.

  ## Options

    * `--from N` — first chapter to download (default: 1)
    * `--to N` — last chapter to download (default: #{@last_chapter})
  """
  @spec main([String.t()]) :: :ok
  def main(args \\ System.argv()) do
    {:ok, _} = Application.ensure_all_started(:hxh_pdf)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          from: :integer,
          to: :integer
        ]
      )

    from = Keyword.get(opts, :from, 1)
    to = Keyword.get(opts, :to, @last_chapter)

    Finch.start_link(
      name: @finch_name,
      pools: %{
        default: [
          size: @default_chapters * @default_images + @default_chapters,
          count: 1,
          conn_opts: [transport_opts: [timeout: 15_000]]
        ]
      }
    )

    File.mkdir_p!(@output_dir)
    cleanup_matching(System.tmp_dir!(), &String.starts_with?(&1, "hxh_ch"), &File.rm_rf/1)
    cleanup_matching(@output_dir, &String.ends_with?(&1, ".cbz.tmp"))

    chapters = Enum.to_list(from..to)
    {skipped, pending} = partition_chapters(chapters)

    if skipped != [] do
      IO.puts("[SKIP] #{length(skipped)} chapters already exist")
    end

    total = length(pending)

    if pending == [] do
      IO.puts("Nothing to download.")
    else
      IO.puts("Downloading #{total} chapters as cbz")

      start_time = System.monotonic_time(:millisecond)

      run_chapters(pending, total)

      elapsed_s = (System.monotonic_time(:millisecond) - start_time) / 1_000
      IO.puts("\nElapsed: #{Float.round(elapsed_s, 1)}s | Done!")
    end
  end

  defp run_chapters(chapters, total) do
    chapters
    |> Task.async_stream(
      fn chapter -> process_chapter(chapter) end,
      max_concurrency: @default_chapters,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(0, fn result, done ->
      done = done + 1
      report_result(result, done, total)
      done
    end)
  end

  @spec process_chapter(pos_integer()) ::
          {:ok, pos_integer(), float()} | {:error, pos_integer(), term(), float()}
  defp process_chapter(chapter) do
    start_time = System.monotonic_time(:millisecond)

    tmp_dir =
      Path.join(System.tmp_dir!(), "hxh_ch#{chapter}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    result =
      with {:ok, image_urls} <- scrape_chapter(chapter),
           :ok <- download_images(image_urls, tmp_dir),
           :ok <- create_archive(tmp_dir, output_path(chapter)) do
        elapsed = (System.monotonic_time(:millisecond) - start_time) / 1_000
        {:ok, chapter, elapsed}
      else
        {:error, reason} ->
          elapsed = (System.monotonic_time(:millisecond) - start_time) / 1_000
          {:error, chapter, reason, elapsed}
      end

    File.rm_rf(tmp_dir)
    result
  end

  defp report_result({:ok, {:ok, chapter, elapsed}}, done, total),
    do: IO.puts("[OK] Chapter #{chapter} in #{Float.round(elapsed, 1)}s (#{done}/#{total})")

  defp report_result({:ok, {:error, chapter, reason, elapsed}}, done, total),
    do:
      IO.puts(
        "[ERROR] Chapter #{chapter}: #{inspect(reason)} after #{Float.round(elapsed, 1)}s (#{done}/#{total})"
      )

  defp report_result({:exit, reason}, done, total),
    do: IO.puts("[EXIT] Task crashed: #{inspect(reason)} (#{done}/#{total})")

  defp partition_chapters(chapters) do
    Enum.split_with(chapters, &File.exists?(output_path(&1)))
  end

  @spec scrape_chapter(pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  defp scrape_chapter(chapter) do
    url = chapter_url(chapter)

    with {:ok, %{status: 200, body: body}} <- http_get(url, max_retries: 3),
         {:ok, doc} <- Floki.parse_document(body, html_parser: Floki.HTMLParser.FastHtml) do
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
    alias HxhPdf.Selectors

    Selectors.image_tiers()
    |> Enum.find_value(fn tier ->
      urls =
        run_tier(doc, tier)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "data:")))
        |> maybe_filter(tier[:filter])
        |> Enum.uniq()

      if urls != [], do: Enum.map(urls, &upgrade_blogger_resolution/1)
    end) || []
  end

  defp maybe_filter(urls, true), do: Enum.filter(urls, &manga_image?/1)
  defp maybe_filter(urls, _), do: urls

  defp run_tier(doc, %{extract: {:attr, attr}} = tier) do
    doc |> Floki.find(tier.selector) |> Floki.attribute(attr)
  end

  @doc false
  def upgrade_blogger_resolution(url) do
    String.replace(
      url,
      HxhPdf.Selectors.blogger_resolution_pattern(),
      HxhPdf.Selectors.blogger_target_resolution()
    )
  end

  @doc false
  def manga_image?(url) do
    not Enum.any?(HxhPdf.Selectors.non_content_patterns(), &String.contains?(url, &1)) and
      has_image_ext_or_cdn?(url)
  end

  @doc false
  def has_image_ext_or_cdn?(url) do
    Enum.any?(HxhPdf.Selectors.cdn_domains(), &String.contains?(url, &1)) or
      Regex.match?(HxhPdf.Selectors.image_ext_regex(), url)
  end

  defp no_images_diagnostic(doc, chapter) do
    diag = HxhPdf.Selectors.diagnostic()
    img_count = doc |> Floki.find(diag.all_images) |> length()
    a_count = doc |> Floki.find(diag.all_links) |> length()

    entry_html =
      case Floki.find(doc, diag.entry_content) do
        [] -> "(no #{diag.entry_content} found)"
        nodes -> nodes |> Floki.raw_html() |> String.slice(0, 500)
      end

    "no images found for chapter #{chapter} | <img>: #{img_count}, <a>: #{a_count} | entry-content preview: #{entry_html}"
  end

  @spec download_images([String.t()], Path.t()) :: :ok | {:error, term()}
  defp download_images(urls, tmp_dir) do
    urls
    |> Enum.with_index(1)
    |> Task.async_stream(&download_one(&1, tmp_dir),
      max_concurrency: @default_images,
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
    case http_get(url, max_retries: 5) do
      {:ok, %{status: 200, body: body}} ->
        File.write!(dest, body)
        :ok

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} downloading #{url}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec http_get(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  defp http_get(url, opts) do
    max_retries = Keyword.get(opts, :max_retries, 3)

    Req.get(url,
      headers: @headers,
      finch: @finch_name,
      retry: :transient,
      max_retries: max_retries,
      receive_timeout: 30_000
    )
  end

  @spec create_archive(Path.t(), Path.t()) :: :ok | {:error, String.t()}
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

  @doc false
  def chapter_url(407), do: "#{@base_url}/hunter-x-hunter-chapter-407-2/"
  def chapter_url(n), do: "#{@base_url}/hunter-x-hunter-chapter-#{n}/"

  @doc false
  def output_path(chapter) do
    padded = chapter |> Integer.to_string() |> String.pad_leading(3, "0")
    Path.join(@output_dir, "Hunter_x_Hunter_#{padded}.cbz")
  end

  @doc false
  def url_extension(url) do
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
