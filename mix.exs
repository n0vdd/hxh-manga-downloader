defmodule HxhPdf.MixProject do
  use Mix.Project

  def project do
    [
      app: :hxh_pdf,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      releases: [hxh_pdf: [strip_beams: true]],
      description: "HxH manga chapter scraper and CBZ archiver",
      package: [licenses: ["GPL-3.0-or-later"]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5.17"},
      {:floki, "~> 0.38.0"},
      {:fast_html, "~> 2.3"},
      {:credo, "~> 1.7", only: [:dev], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end
end
