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
./hxh_pdf
```

Downloads all 412 chapters to `./output/` as `Hunter_x_Hunter_XXX.cbz`. Images are optimized with ImageMagick by default. Existing chapters are skipped automatically.

## Architecture

Four modules:

- **`HxhPdf`** — Entry point, argument parsing, scraping, image downloading, and CBZ creation. Processes up to 3 chapters concurrently, each downloading up to 8 images concurrently. Uses [Req](https://github.com/wojtekmach/req) for HTTP and [Floki](https://github.com/philss/floki) for HTML parsing.
- **`HxhPdf.Http`** — HTTP client wrapping Req + Finch. Every request goes through FlowControl gating, with automatic retries and exponential backoff.
- **`HxhPdf.FlowControl`** — GenServer acting as an adaptive permit semaphore. Permits increase after sustained success and decrease on errors, keeping downstream pressure in check.
- **`HxhPdf.Shutdown`** — Lock-free graceful shutdown flag using `:atomics` + `:persistent_term`. SIGTERM flips the flag to stop launching new work.
