# hxh-manga-downloader

Elixir CLI tool that scrapes Hunter x Hunter manga chapters from the web and packages them as CBZ archives. Optionally optimizes images via ImageMagick (grayscale, strip metadata, reduce quality).

## Requirements

- Elixir 1.15+ / Erlang OTP
- ImageMagick (`magick` command) — only needed for image optimization

## Build

```bash
mix deps.get
mix escript.build
```

## Usage

```bash
# Download all 412 chapters (default)
./hxh_pdf

# Download a specific range
./hxh_pdf --from 1 --to 10

# Skip image optimization
./hxh_pdf --from 50 --to 100 --no-optimize
```

### CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--from N` | 1 | First chapter to download |
| `--to N` | 412 | Last chapter to download |
| `--no-optimize` | (optimize on) | Skip ImageMagick grayscale/strip/quality reduction |

Output goes to `./output/` as `Hunter_x_Hunter_XXX.cbz`. Existing chapters are skipped automatically.

## Architecture

Single module (`HxhPdf` in `lib/hxh_pdf.ex`):

- Processes 4 chapters concurrently via `Task.async_stream`, each downloading up to 6 images concurrently
- Finch connection pool sized at 28 (`4 * 6 + 4`)
- Uses [Floki](https://github.com/philss/floki) for HTML parsing and [Req](https://github.com/wojtekmach/req) + Finch for HTTP with transient retries

**Pipeline per chapter:** check if CBZ exists (skip) → scrape image URLs from HTML → download images to temp dir → optionally optimize with ImageMagick → create CBZ via Erlang `:zip` → cleanup temp dir.

## Performance

Throughput is ~10s/chapter, bottlenecked by the upstream server. Increasing concurrency beyond the current defaults doesn't help.
