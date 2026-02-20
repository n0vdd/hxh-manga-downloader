defmodule HxhPdf.Shutdown do
  @moduledoc """
  Lock-free graceful shutdown flag using `:atomics`.

  `init/0` creates a single-element atomics reference stored in
  `:persistent_term`. Any process can then call `request/0` to flip the flag
  and `requested?/0` to check it, both without blocking or message passing.

  Used by the SIGTERM handler to signal `run_chapters` to stop launching new
  work while letting in-flight chapters finish.
  """

  @key {__MODULE__, :ref}

  def init do
    ref = :atomics.new(1, signed: false)
    :persistent_term.put(@key, ref)
  end

  def request do
    :atomics.put(:persistent_term.get(@key), 1, 1)
  end

  def requested? do
    :atomics.get(:persistent_term.get(@key), 1) == 1
  end
end
