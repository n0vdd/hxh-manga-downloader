# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Elixir CLI (Mix release) that scrapes Hunter x Hunter manga chapters from w19.read-hxh.com and packages them as CBZ archives with original full-resolution images.

## Commands

```bash
mix deps.get                                # Install dependencies
MIX_ENV=prod mix release                    # Build the release
_build/prod/rel/hxh_pdf/bin/hxh --from 1 --to 10               # Download chapters 1-10 (defaults: 1 to 412)
mix test                                    # Run tests
mix format                                  # Format code
mix credo --strict                          # Lint
mix dialyzer                                # Static type analysis
```

## System Requirements

- Elixir 1.15+ / Erlang OTP
- C compiler + `make` (needed by `fast_html` NIF)

## Architecture

Two modules:

- **`hxh_pdf.ex`** — Entry point (`main/1`), argument parsing, scraping, image downloading, and CBZ creation. Downloads original full-resolution images without any optimization. Processes 4 chapters concurrently via `Task.async_stream`, each downloading up to 6 images concurrently. Finch pool sized at 28 (`4 * 6 + 4`). Uses Floki (with FastHtml backend) for HTML parsing, Req + Finch for HTTP with transient retries.
- **`hxh_pdf/selectors.ex`** — Site-specific CSS selectors, CDN patterns, and image-filtering heuristics for w19.read-hxh.com. Defines tiered image extraction strategies (blogger links, blogger imgs, laiond imgs, generic fallback) and resolution upscaling rules.

**Pipeline:** `process_chapter` → check if CBZ exists (skip) → scrape image URLs from HTML → download images to temp dir → create CBZ via Erlang `:zip` → cleanup temp dir.

Output goes to `./output/` as `Hunter_x_Hunter_XXX.cbz`.

## Tests

- `test/hxh_pdf_test.exs` — Unit tests for `HxhPdf` public helpers (URL building, filename extraction, arg parsing).
- `test/hxh_pdf/selectors_test.exs` — Unit tests for `HxhPdf.Selectors` (image extraction strategies, URL upscaling, filtering).

## Performance

~10s/chapter, bottlenecked by the upstream server. Increasing concurrency doesn't help.
