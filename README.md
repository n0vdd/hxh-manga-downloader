# hxh-manga-downloader

Elixir CLI tool that scrapes Hunter x Hunter manga chapters from w19.read-hxh.com and packages them as CBZ archives with original full-resolution images.

## Download (experimental)

Pre-built Linux x86_64 binaries are available on the [Releases](../../releases) page. These are self-contained and include the Erlang runtime — no dependencies needed.

```bash
tar -xzf hxh-manga-downloader-linux-x86_64.tar.gz -C hxh-manga-downloader
cd hxh-manga-downloader
./bin/hxh --from 1 --to 10
```

## Requirements

- Elixir 1.15+ / Erlang OTP
- C compiler + `make` (needed by `fast_html` NIF)

## Build

```bash
mix deps.get
MIX_ENV=prod mix release
mix test                    # run tests
```

## Usage

```bash
# Download all 412 chapters (default)
_build/prod/rel/hxh_pdf/bin/hxh

# Download a specific range
_build/prod/rel/hxh_pdf/bin/hxh --from 1 --to 10
```

### CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--from N` | 1 | First chapter to download |
| `--to N` | 412 | Last chapter to download |

Output goes to `./output/` as `Hunter_x_Hunter_XXX.cbz`. Existing chapters are skipped automatically.

## Architecture

Two modules:

- **`HxhPdf`** (`lib/hxh_pdf.ex`) — Entry point (`main/1`), argument parsing, scraping, image downloading, and CBZ creation.
- **`HxhPdf.Selectors`** (`lib/hxh_pdf/selectors.ex`) — Site-specific CSS selectors, CDN patterns, and image-filtering heuristics.

Processes 4 chapters concurrently via `Task.async_stream`, each downloading up to 6 images concurrently. Finch connection pool sized at 28 (`4 * 6 + 4`). Uses [Floki](https://github.com/philss/floki) (with FastHtml backend) for HTML parsing and [Req](https://github.com/wojtekmach/req) + Finch for HTTP with transient retries.

**Pipeline per chapter:** check if CBZ exists (skip) → scrape image URLs from HTML → download images to temp dir → create CBZ via Erlang `:zip` → cleanup temp dir.

## Performance

Throughput is ~10s/chapter, bottlenecked by the upstream server. Increasing concurrency beyond the current defaults doesn't help.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
