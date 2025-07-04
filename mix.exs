defmodule Tasque.MixProject do
  use Mix.Project

  def project do
    [
      app: :tasque,
      version: "0.1.0",
      elixir: "~> 1.18.3",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),

      # Docs
      name: "Tasque",
      source_url: "https://github.com/FormlessEvoker.com/tasque",
      homepage_url: "https://github.com/FormlessEvoker.com/tasque",
      docs: &docs/0
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    [
      setup: [
        "deps.get",
        "git_hooks.install"
      ],
      test: ["test --color"]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4"},
      {:ex_doc, "~> 0.38.2", only: :dev, runtime: false, warn_if_outdated: true},
      {:git_hooks, "~> 0.8.1", only: [:dev], runtime: false},
      {:hammox, "~> 0.7", only: :test},
      {:mix_test_watch, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Tasque",
      extras: ["README.md"]
    ]
  end
end
