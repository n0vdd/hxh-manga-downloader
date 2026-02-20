defmodule HxhPdf do
  @moduledoc false

  @base_url "https://w19.read-hxh.com/manga"
  @output_dir "output"
  @default_headers [
    {"user-agent", "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"},
    {"referer", "https://w19.read-hxh.com/"}
  ]

  def main(args \\ System.argv()) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [from: :integer, to: :integer, no_optimize: :boolean]
      )

    from = Keyword.get(opts, :from, 1)
    to = Keyword.get(opts, :to, 412)
    optimize = not Keyword.get(opts, :no_optimize, false)

    File.mkdir_p!(@output_dir)
    {:ok, _} = HxhPdf.RateLimiter.start_link()

    chapters = Enum.to_list(from..to)
    total = length(chapters)

    opt_label = if optimize, do: ", optimized", else: ""
    IO.puts("Downloading chapters #{from}-#{to} as cbz (#{total} chapters#{opt_label})")

    chapters
    |> Task.async_stream(&process_chapter(&1, optimize),
      max_concurrency: 3,
      timeout: :infinity
    )
    |> Enum.each(fn
      {:ok, {:ok, chapter}} ->
        IO.puts("[OK] Chapter #{chapter}")

      {:ok, {:skip, chapter}} ->
        IO.puts("[SKIP] Chapter #{chapter} (already exists)")

      {:ok, {:error, chapter, reason}} ->
        IO.puts("[ERROR] Chapter #{chapter}: #{inspect(reason)}")

      {:exit, reason} ->
        IO.puts("[EXIT] Task crashed: #{inspect(reason)}")
    end)

    IO.puts("Done!")
  end

  defp process_chapter(chapter, optimize) do
    output_file = output_path(chapter)

    if File.exists?(output_file) do
      {:skip, chapter}
    else
      tmp_dir =
        Path.join(System.tmp_dir!(), "hxh_ch#{chapter}_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        with {:ok, image_urls} <- scrape_chapter(chapter),
             :ok <- download_images(image_urls, tmp_dir, optimize),
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
    HxhPdf.RateLimiter.acquire()

    case Req.get(url, headers: @default_headers, retry: :transient, max_retries: 3) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, doc} = Floki.parse_document(body)
        urls = extract_image_urls(doc)

        if urls == [] do
          {:error, "no images found for chapter #{chapter}"}
        else
          {:ok, urls}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} for #{url}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_image_urls(doc) do
    blogger_urls =
      doc
      |> Floki.find(".entry-content a[href*='blogger']")
      |> Floki.attribute("href")

    if blogger_urls != [] do
      blogger_urls |> Enum.uniq()
    else
      doc
      |> Floki.find(".entry-content img[src*='laiond']")
      |> Floki.attribute("src")
      |> Enum.uniq()
    end
  end

  defp download_images(urls, tmp_dir, optimize) do
    urls
    |> Enum.with_index(1)
    |> Task.async_stream(&download_one(&1, tmp_dir, optimize),
      max_concurrency: 4,
      timeout: 60_000
    )
    |> Enum.to_list()
    |> check_results()
  end

  defp download_one({url, idx}, tmp_dir, optimize) do
    padded = idx |> Integer.to_string() |> String.pad_leading(3, "0")
    ext = url_extension(url)
    dest = Path.join(tmp_dir, "#{padded}#{ext}")

    with :ok <- download_image(url, dest) do
      if optimize, do: optimize_image(dest), else: :ok
    end
  end

  defp check_results(results) do
    crashed = Enum.find(results, fn {status, _} -> status == :exit end)
    failed = Enum.find(results, fn {_, result} -> result != :ok end)

    cond do
      crashed -> {:error, "download task crashed: #{inspect(elem(crashed, 1))}"}
      failed -> {:error, elem(elem(failed, 1), 1)}
      true -> :ok
    end
  end

  defp url_extension(url) do
    uri = URI.parse(url)

    case Path.extname(uri.path || "") do
      "" -> ".jpg"
      ext -> ext
    end
  end

  defp download_image(url, dest) do
    HxhPdf.RateLimiter.acquire()

    case Req.get(url,
           headers: @default_headers,
           retry: :transient,
           max_retries: 3,
           receive_timeout: 30_000,
           into: File.stream!(dest)
         ) do
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
    files =
      tmp_dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.map(fn name ->
        {String.to_charlist(name), File.read!(Path.join(tmp_dir, name))}
      end)

    case :zip.create(String.to_charlist(output_file), files) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "zip failed: #{inspect(reason)}"}
    end
  end

end
