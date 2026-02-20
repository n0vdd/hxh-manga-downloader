defmodule HxhPdf.MixProject do
  use Mix.Project

  def project do
    [
      app: :hxh_pdf,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: HxhPdf],
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
      {:credo, "~> 1.7", only: [:dev], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end
end
