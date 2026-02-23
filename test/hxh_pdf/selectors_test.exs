defmodule HxhPdf.SelectorsTest do
  use ExUnit.Case, async: true

  alias HxhPdf.Selectors

  describe "image_ext_regex/0" do
    test "matches common image extensions" do
      regex = Selectors.image_ext_regex()

      for ext <- ~w(.jpg .jpeg .png .webp .gif) do
        assert Regex.match?(regex, "https://example.com/image#{ext}"),
               "expected to match #{ext}"
      end
    end

    test "matches extensions with query strings" do
      regex = Selectors.image_ext_regex()
      assert Regex.match?(regex, "https://example.com/image.png?w=800")
      assert Regex.match?(regex, "https://example.com/image.jpg?quality=high")
    end

    test "is case-insensitive" do
      regex = Selectors.image_ext_regex()
      assert Regex.match?(regex, "https://example.com/image.PNG")
      assert Regex.match?(regex, "https://example.com/image.JPG")
    end

    test "rejects non-image extensions" do
      regex = Selectors.image_ext_regex()

      for ext <- ~w(.pdf .html .txt .css .js) do
        refute Regex.match?(regex, "https://example.com/file#{ext}"),
               "expected NOT to match #{ext}"
      end
    end
  end

  describe "blogger_resolution_pattern/0" do
    test "matches /sNNN/ patterns" do
      pattern = Selectors.blogger_resolution_pattern()
      assert Regex.match?(pattern, "/s400/")
      assert Regex.match?(pattern, "/s1024/")
      assert Regex.match?(pattern, "/s0/")
    end

    test "does not match non-resolution paths" do
      pattern = Selectors.blogger_resolution_pattern()
      refute Regex.match?(pattern, "/slow/")
      refute Regex.match?(pattern, "/style/")
    end
  end

  describe "non_content_patterns/0" do
    test "returns expected blocklist" do
      patterns = Selectors.non_content_patterns()
      assert is_list(patterns)
      assert "ko-fi" in patterns
      assert "gravatar" in patterns
      assert "wp-content/plugins" in patterns
    end
  end

  describe "cdn_domains/0" do
    test "returns expected domains" do
      domains = Selectors.cdn_domains()
      assert is_list(domains)
      assert "blogger" in domains
      assert "laiond" in domains
    end
  end

  describe "image_tiers/0" do
    test "returns 4 tiers" do
      tiers = Selectors.image_tiers()
      assert length(tiers) == 4
    end

    test "first tier targets blogger links" do
      [first | _] = Selectors.image_tiers()
      assert first.selector =~ "blogger"
      assert first.extract == {:attr, "href"}
    end

    test "last tier has filter: true" do
      last = List.last(Selectors.image_tiers())
      assert last[:filter] == true
    end
  end
end
