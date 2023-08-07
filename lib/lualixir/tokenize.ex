defmodule Lualixir.Tokenize do
  @keywords ~w[and break do else elseif end false for function gogo if in local nil not or repeat return then true until while]

  @token_chars [
    ?#,
    ?%,
    ?&,
    ?(,
    ?),
    ?*,
    ?+,
    ?,,
    ?-,
    ?.,
    ?/,
    ?:,
    ?;,
    ?<,
    ?=,
    ?>,
    ?[,
    ?],
    ?^,
    ?{,
    ?|,
    ?},
    ?~
  ]
  @tokens ~w[+ - * / % ^ # & ~ | << >> // == ~= <= >= < > = ( ) { } [ \] :: ; : , . .. ...]

  # TODO : check end state, e.g. a string that's still open at the end of the program should crash
  # the tokenizer

  def tokenize(program) do
    program
    |> StringIO.open()
    |> elem(1)
    |> IO.binstream(1)
    |> Stream.transform({1, 1, 1, nil, nil, nil, []}, &next/2)
    # if you remove the to_list, the catch will need to be in the thing that calls it
    |> Enum.to_list()
    |> then(&{:ok, &1})
  catch
    {reason, _char, row, column, byte, _buf, _mode, _state, _emit} ->
      {:error, reason, {row, column, byte}}
  end

  def next(char, {row, column, byte, buf, mode, state, emit}) do
    <<ch::utf8>> = char

    case mode do
      nil ->
        case ch do
          x when x == ?\n or x == ?\r ->
            if state != x && (state == "\r" || state == "\n") do
              {emit, {row, column, byte + 1, nil, nil, nil, []}}
            else
              {emit, {row + 1, 1, byte + 1, nil, nil, x, []}}
            end

          x when x == 32 or x == ?\t or x == ?\f or x == ?\v ->
            {emit, {row, column + 1, byte + 1, nil, nil, nil, []}}

          x when x in ?a..?z or x in ?A..?Z or x == ?_ ->
            {emit, {row, column + 1, byte + 1, char, :name, nil, []}}

          x when x in @token_chars ->
            {emit, {row, column + 1, byte + 1, char, :token, nil, []}}

          x when x in ?0..?9 ->
            {emit, {row, column + 1, byte + 1, char, :numeral, nil, []}}

          x when x == ?" or x == ?' ->
            {emit, {row, column + 1, byte + 1, "", :string, {ch, false}, []}}

          _ ->
            throw({"unrecognised character", char, row, column, byte, buf, mode, state, emit})
        end

      :name ->
        case ch do
          x when x in ?a..?z or x in ?A..?Z or x in ?0..?9 or x == ?_ ->
            {emit, {row, column + 1, byte + 1, buf <> char, :name, nil, []}}

          _ ->
            if buf in @keywords do
              next(char, {row, column, byte, nil, nil, nil, [{:keyword, buf}]})
            else
              next(char, {row, column, byte, nil, nil, nil, [{:name, buf}]})
            end
        end

      :token ->
        case ch do
          x when x in @token_chars ->
            {emit, {row, column + 1, byte + 1, buf <> char, :token, nil, []}}

          _ ->
            case buf do
              "--[" <> rest ->
                if Regex.match?(~r/=*\[.*/, rest) do
                  throw(
                    {{:not_implemented, "long bracket comments"}, char, row, column, byte, buf,
                     mode, state, emit}
                  )
                else
                  next(char, {row, column, byte, nil, :comment, nil, []})
                end

              "--" <> _ ->
                next(char, {row, column, byte, nil, :comment, nil, []})

              "[[" <> _ ->
                throw(
                  {{:not_implemented, "long bracket strings"}, char, row, column, byte, buf, mode,
                   state, emit}
                )

              "[=" <> _ ->
                throw(
                  {{:not_implemented, "long bracket strings"}, char, row, column, byte, buf, mode,
                   state, emit}
                )

              _ ->
                case break_down_tokens(buf) do
                  {:ok, tokens} ->
                    output = Enum.map(tokens, &{:token, &1})
                    next(char, {row, column, byte, nil, nil, nil, output})

                  :error ->
                    throw({:invalid_token, char, row, column, byte, buf, mode, state, emit})
                end
            end
        end

      :comment ->
        case ch do
          x when x == ?\n or x == ?\r ->
            next(char, {row, column, byte, nil, nil, nil, []})

          _ ->
            {emit, {row, column + 1, byte + 1, nil, :comment, nil, []}}
        end

      :numeral ->
        case ch do
          x when x in ?0..?9 ->
            {emit, {row, column + 1, byte + 1, buf <> char, :numeral, nil, []}}

          ?. ->
            if String.contains?(buf, ".") do
              throw({:invalid_number, char, row, column, byte, buf, mode, state, emit})
            else
              {emit, {row, column + 1, byte + 1, buf <> char, :numeral, nil, []}}
            end

          ?x ->
            if String.length(buf) == 1 do
              {emit, {row, column, byte, buf <> char, :numeral_hex, nil, []}}
            else
              throw({:invalid_number, char, row, column, byte, buf, mode, state, emit})
            end

          x when x == ?e or x == ?E ->
            {emit, {row, column + 1, byte + 1, buf <> char, :numeral_exponent, true, []}}

          _ ->
            {number, ""} =
              if String.contains?(buf, ".") do
                Float.parse(buf)
              else
                Integer.parse(buf)
              end

            next(char, {row, column, byte, nil, nil, nil, [{:numeral, number}]})
        end

      :numeral_hex ->
        throw(
          {{:not_implemented, "hex numbers"}, char, row, column, byte, buf, mode, state, emit}
        )

      :numeral_exponent ->
        case ch do
          x when x in ?0..?9 ->
            {emit, {row, column + 1, byte + 1, buf <> char, :numeral_exponent, nil, []}}

          ?- ->
            if state do
              {emit, {row, column + 1, byte + 1, buf <> char, :numeral_exponent, nil, []}}
            else
              throw({:invalid_number, char, row, column, byte, buf, mode, state, emit})
            end

          _ ->
            {number, ""} = Float.parse(buf)
            next(char, {row, column, byte, nil, nil, nil, [{:numeral, number}]})
        end

      :string ->
        {opening, escaped} = state

        cond do
          ch == ?\r || ch == ?\n ->
            throw({:unfinished_string, char, row, column, byte, buf, mode, state, emit})

          escaped && ch == ?z ->
            throw(
              {{:not_implemented, "skip following whitespace escape"}, char, row, column, byte,
               buf, mode, state, emit}
            )

          escaped && ch == ?u ->
            throw(
              {{:not_implemented, "unicode in strings"}, char, row, column, byte, buf, mode,
               state, emit}
            )

          escaped && ch == ?x ->
            {emit, {row, column + 1, byte + 1, buf, :string_hex, {opening, nil}, []}}

          escaped && ch in ?0..?9 ->
            {emit, {row, column + 1, byte + 1, buf, :string_decimal, {opening, char}, []}}

          escaped ->
            new_char =
              case ch do
                ?a -> "\a"
                ?b -> "\b"
                ?f -> "\f"
                ?n -> "\n"
                ?r -> "\r"
                ?t -> "\t"
                ?v -> "\v"
                _ -> char
              end

            {emit, {row, column + 1, byte + 1, buf <> new_char, :string, {opening, false}, []}}

          ch == ?\\ ->
            {emit, {row, column + 1, byte + 1, buf, :string, {opening, true}, []}}

          ch != opening ->
            {emit, {row, column + 1, byte + 1, buf <> char, :string, {opening, false}, []}}

          true ->
            {emit ++ [string: buf], {row, column + 1, byte + 1, nil, nil, nil, []}}
        end

      :string_hex ->
        {opening, acc} = state

        case ch do
          x when x in ?0..?9 or x in ?a..?f or x in ?A..?F ->
            if acc do
              {value, ""} = Integer.parse(acc <> char, 16)
              new_char = List.to_string([value])
              {emit, {row, column + 1, byte + 1, buf <> new_char, :string, {opening, false}, []}}
            else
              {emit, {row, column + 1, byte + 1, buf, :string_hex, {opening, char}, []}}
            end

          _ ->
            throw({:invalid_hexadecimal_escape, char, row, column, byte, buf, mode, state, emit})
        end

      :string_decimal ->
        {opening, acc} = state

        case ch do
          x when x in ?0..?9 ->
            {emit, {row, column + 1, byte + 1, buf, :string_decimal, {opening, acc <> char}, []}}

          _ ->
            {value, ""} = Integer.parse(acc)

            if value > 255 do
              throw({:invalid_decimal_escape, char, row, column, byte, buf, mode, state, emit})
            end

            new_char = List.to_string([value])

            next(
              char,
              {row, column + 1, byte + 1, buf <> new_char, :string, {opening, false}, []}
            )
        end
    end
  end

  defp break_down_tokens(token, tokens \\ [])

  defp break_down_tokens("", tokens), do: {:ok, tokens}
  defp break_down_tokens(token, tokens) when token in @tokens, do: {:ok, [token] ++ tokens}

  defp break_down_tokens(token, tokens) do
    if String.length(token) == 1 do
      :error
    else
      case split_apart_token(token, String.length(token) - 1) do
        {:ok, first, second} -> break_down_tokens(second, [first] ++ tokens)
        :error -> :error
      end
    end
  end

  defp split_apart_token(token, length) do
    {first, second} = String.split_at(token, length)

    cond do
      first in @tokens -> {:ok, first, second}
      length > 1 -> split_apart_token(token, length - 1)
      true -> :error
    end
  end
end
