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

Four modules:

- **`hxh_pdf.ex`** — Entry point (`main/1`), argument parsing, scraping, image downloading, and CBZ creation. Processes up to 3 chapters concurrently via `Task.async`, each downloading up to 8 images concurrently via `Task.async_stream`. Uses Floki for HTML parsing.

- **`http.ex`** — HTTP client wrapping Req + Finch. Every request goes through FlowControl gating, with automatic retries and exponential backoff.

- **`flow_control.ex`** — GenServer acting as an adaptive permit semaphore. Permits increase after sustained success and decrease on errors, keeping downstream pressure in check.

- **`shutdown.ex`** — Lock-free graceful shutdown flag using `:atomics` + `:persistent_term`. SIGTERM flips the flag; `run_chapters` checks it to stop launching new work.

**Pipeline:** `process_chapter` → check if CBZ exists (skip) → scrape image URLs from HTML → download images to temp dir → optionally optimize with ImageMagick → create CBZ via Erlang `:zip` → cleanup temp dir.

Output goes to `./output/` as `Hunter_x_Hunter_XXX.cbz`.
