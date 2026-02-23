defmodule HxhPdfTest do
  use ExUnit.Case, async: true

  describe "chapter_url/1" do
    test "regular chapter" do
      assert HxhPdf.chapter_url(1) == "https://w19.read-hxh.com/manga/hunter-x-hunter-chapter-1/"

      assert HxhPdf.chapter_url(100) ==
               "https://w19.read-hxh.com/manga/hunter-x-hunter-chapter-100/"
    end

    test "chapter 407 has special -2 suffix" do
      assert HxhPdf.chapter_url(407) ==
               "https://w19.read-hxh.com/manga/hunter-x-hunter-chapter-407-2/"
    end
  end

  describe "output_path/1" do
    test "zero-pads single-digit chapters" do
      assert HxhPdf.output_path(1) == "output/Hunter_x_Hunter_001.cbz"
    end

    test "zero-pads double-digit chapters" do
      assert HxhPdf.output_path(10) == "output/Hunter_x_Hunter_010.cbz"
    end

    test "triple-digit chapters need no padding" do
      assert HxhPdf.output_path(412) == "output/Hunter_x_Hunter_412.cbz"
    end
  end

  describe "url_extension/1" do
    test "extracts .png" do
      assert HxhPdf.url_extension("https://example.com/image.png") == ".png"
    end

    test "extracts extension with query string" do
      assert HxhPdf.url_extension("https://example.com/image.webp?w=800") == ".webp"
    end

    test "defaults to .jpg when no extension" do
      assert HxhPdf.url_extension("https://example.com/image") == ".jpg"
    end

    test "defaults to .jpg for empty path" do
      assert HxhPdf.url_extension("https://example.com") == ".jpg"
    end
  end

  describe "manga_image?/1" do
    test "accepts blogger image URL" do
      assert HxhPdf.manga_image?("https://blogger.googleusercontent.com/img/abc.jpg")
    end

    test "accepts laiond CDN URL" do
      assert HxhPdf.manga_image?("https://laiond.com/uploads/abc.png")
    end

    test "rejects gravatar URL" do
      refute HxhPdf.manga_image?("https://secure.gravatar.com/avatar/abc.jpg")
    end

    test "rejects ko-fi URL" do
      refute HxhPdf.manga_image?("https://ko-fi.com/img/abc.png")
    end

    test "rejects random non-image URL" do
      refute HxhPdf.manga_image?("https://example.com/page")
    end
  end

  describe "has_image_ext_or_cdn?/1" do
    test "matches CDN domain" do
      assert HxhPdf.has_image_ext_or_cdn?("https://blogger.googleusercontent.com/noext")
    end

    test "matches image extension" do
      assert HxhPdf.has_image_ext_or_cdn?("https://example.com/file.png")
    end

    test "rejects non-image non-CDN URL" do
      refute HxhPdf.has_image_ext_or_cdn?("https://example.com/page")
    end
  end

  describe "upgrade_blogger_resolution/1" do
    test "replaces /s400/ with /s0/" do
      url = "https://blogger.googleusercontent.com/img/s400/photo.jpg"
      assert HxhPdf.upgrade_blogger_resolution(url) =~ "/s0/"
      refute HxhPdf.upgrade_blogger_resolution(url) =~ "/s400/"
    end

    test "replaces /s1024/ with /s0/" do
      url = "https://blogger.googleusercontent.com/img/s1024/photo.jpg"
      assert HxhPdf.upgrade_blogger_resolution(url) =~ "/s0/"
      refute HxhPdf.upgrade_blogger_resolution(url) =~ "/s1024/"
    end

    test "leaves URL without pattern unchanged" do
      url = "https://example.com/image.jpg"
      assert HxhPdf.upgrade_blogger_resolution(url) == url
    end

    test "idempotent on already /s0/ URL" do
      url = "https://blogger.googleusercontent.com/img/s0/photo.jpg"
      assert HxhPdf.upgrade_blogger_resolution(url) == url
    end
  end
end
