defmodule Lualixir do
  alias Lualixir.Tokenize

  @program """
    -- defines a factorial function
    function fact (n)
      if n == 0 then
        return 1
      else
        return n * fact(n-1)
      end
    end -- comment go
    
    print("enter a numb\\"\\ner\\x21\\65\\234 ")
    a = 4
    print(fact(a))
  """

  def tokenize(program) do
    case Tokenize.tokenize(program) do
      {:ok, stream} ->
        stream
        |> IO.inspect(limit: :infinity)

      {:error, reason, {row, column, byte}} ->
        message =
          case reason do
            {:not_implemented, feature} -> "#{feature} is not yet implemented"
            other -> to_string(other) |> String.replace("_", " ")
          end

        IO.write(:stderr, "Parse error: #{message} in row #{row} column #{column} (byte #{byte})")
    end
  end

  def run, do: tokenize(@program)

  def b, do: Lualixir.tokenize(File.read!("/Users/mogest/downloads/dropboxapi.lua"))
end
