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
# Download chapters 1 through 10
./hxh_pdf --from 1 --to 10

# Download without image optimization
./hxh_pdf --from 50 --to 100 --no-optimize
```

Output goes to `./output/` as `Hunter_x_Hunter_XXX.cbz`. Existing chapters are skipped automatically.

## Architecture

Two modules:

- **`HxhPdf`** — Entry point, argument parsing, scraping, downloading, and CBZ creation. Processes up to 3 chapters concurrently, each downloading up to 4 images concurrently. Uses [Req](https://github.com/wojtekmach/req) for HTTP and [Floki](https://github.com/philss/floki) for HTML parsing.
- **`HxhPdf.RateLimiter`** — GenServer enforcing 5 requests/second across all concurrent tasks.
