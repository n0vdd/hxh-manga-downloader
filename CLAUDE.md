# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Elixir CLI escript that scrapes Hunter x Hunter manga chapters from w19.read-hxh.com and packages them as CBZ archives. Optionally optimizes images via ImageMagick (grayscale, strip metadata, reduce quality).

## Commands

```bash
mix deps.get              # Install dependencies
mix escript.build         # Build the ./hxh_pdf binary
./hxh_pdf --from 1 --to 10               # Download chapters 1-10 (defaults: 1 to 412)
./hxh_pdf --from 50 --to 100 --no-optimize  # Download without image optimization
mix format                # Format code
mix credo --strict        # Lint
mix dialyzer              # Static type analysis
```

## System Requirements

- Elixir 1.15+ / Erlang OTP
- ImageMagick (`magick` command) for image optimization

## Architecture

Single module:

- **`hxh_pdf.ex`** — Entry point (`main/1`), argument parsing, scraping, image downloading, and CBZ creation. Processes 4 chapters concurrently via `Task.async_stream`, each downloading up to 6 images concurrently. Finch pool sized at 28 (`4 * 6 + 4`). Uses Floki for HTML parsing, Req + Finch for HTTP with transient retries.

**Pipeline:** `process_chapter` → check if CBZ exists (skip) → scrape image URLs from HTML → download images to temp dir → optionally optimize with ImageMagick → create CBZ via Erlang `:zip` → cleanup temp dir.

Output goes to `./output/` as `Hunter_x_Hunter_XXX.cbz`.

## Performance

~10s/chapter, bottlenecked by the upstream server. Increasing concurrency doesn't help.
