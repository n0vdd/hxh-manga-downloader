# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Elixir CLI escript that scrapes Hunter x Hunter manga chapters from w19.read-hxh.com and packages them as CBZ archives. Optionally optimizes images via ImageMagick (grayscale, strip metadata, reduce quality).

## Commands

```bash
mix deps.get              # Install dependencies
mix escript.build         # Build the ./hxh_pdf binary
./hxh_pdf --from 1 --to 10               # Download chapters 1-10
./hxh_pdf --from 50 --to 100 --no-optimize  # Download without image optimization
mix format                # Format code
mix credo --strict        # Lint
mix dialyzer              # Static type analysis
```

## System Requirements

- Elixir 1.15+ / Erlang OTP
- ImageMagick (`magick` command) for image optimization

## Architecture

Two modules in `lib/hxh_pdf/`:

- **`hxh_pdf.ex`** — Entry point (`main/1`), argument parsing, scraping, downloading, and CBZ creation. Processes up to 3 chapters concurrently via `Task.async_stream`, each downloading up to 4 images concurrently. Uses Req for HTTP (with 3 retries, 60s timeout) and Floki for HTML parsing.

- **`rate_limiter.ex`** — GenServer enforcing 5 requests/second across all concurrent tasks. Called before each HTTP request.

**Pipeline:** `process_chapter` → check if CBZ exists (skip) → scrape image URLs from HTML → download images to temp dir → optionally optimize with ImageMagick → create CBZ via Erlang `:zip` → cleanup temp dir.

Output goes to `./output/` as `Hunter_x_Hunter_XXX.cbz`.
