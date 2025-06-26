defmodule TasqueTest do
  use ExUnit.Case
  doctest Tasque

  test "greets the world" do
    assert Tasque.hello() == :world
  end
end
