defmodule HxhPdf.Selectors do
  @moduledoc "Site-specific selectors and patterns for w19.read-hxh.com"

  # Each tier: %{selector, extract, filter?}
  # extract is {:attr, "href"} → Floki.find + Floki.attribute
  @image_tiers [
    %{selector: ".entry-content a[href*='blogger']", extract: {:attr, "href"}},
    %{selector: ".entry-content img[src*='blogger']", extract: {:attr, "src"}},
    %{selector: ".entry-content img[src*='laiond']", extract: {:attr, "src"}},
    %{selector: ".entry-content img", extract: {:attr, "src"}, filter: true}
  ]

  @diagnostic %{
    all_images: "img",
    all_links: "a",
    entry_content: ".entry-content"
  }

  @non_content_patterns ~w(ko-fi wp-content/plugins gravatar)
  @cdn_domains ~w(blogger laiond)
  @image_ext_regex ~r/\.(?:jpe?g|png|webp|gif)(?:\?|$)/i
  @blogger_resolution_pattern ~r{/s\d+/}
  @blogger_target_resolution "/s0/"

  def image_tiers, do: @image_tiers
  def diagnostic, do: @diagnostic
  def non_content_patterns, do: @non_content_patterns
  def cdn_domains, do: @cdn_domains
  def image_ext_regex, do: @image_ext_regex
  def blogger_resolution_pattern, do: @blogger_resolution_pattern
  def blogger_target_resolution, do: @blogger_target_resolution
end
