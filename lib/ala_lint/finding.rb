module AlaLint
  # One finding: which check raised it, where, and the words a reader acts on.
  Finding = Data.define(:check, :message, :unit, :file, :line) do
    def to_h = { check: check, message: message, unit: unit, file: file, line: line }
  end
end
