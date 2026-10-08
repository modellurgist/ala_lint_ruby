module AlaLint
  # A reviewer's decision written in the code: `# ala:accept r3` accepts the next line for the named
  # check (several: `r3,r5`; more lines: `lines=3`; a reason after `--`). In ERB, `<%# ala:accept ... %>`.
  # The linter can't tell an application literal from a domain's own word, or routing from logic;
  # the person reading the finding can, and this records the call where the code is.
  Acceptance = Data.define(:file, :line, :checks, :from, :to, :reason) do
    PATTERN = /ala:accept\s+([a-z0-9_]+(?:,[a-z0-9_]+)*)(?:\s+lines=(\d+))?(?:\s+--\s*(.*?))?\s*(?:%>)?\s*\z/

    def self.scan(source, file)
      source.lines.each_with_index.filter_map do |text, i|
        next unless (m = PATTERN.match(text.chomp)) && text.match?(/(#|<%#)\s*ala:accept/)
        checks = m[1].split(",").map(&:to_sym)
        unknown = checks.reject { Checks::BY_NAME.key?(_1) }
        raise ArgumentError, "#{file}:#{i + 1}: ala:accept names no such check: #{unknown.join(', ')} (see --list-checks)" unless unknown.empty?
        count = (m[2] || 1).to_i
        new(file:, line: i + 1, checks:, from: i + 2, to: i + 1 + count, reason: m[3].to_s.strip)
      end
    end

    def covers?(finding) = finding.file == file && checks.include?(finding.check) && (from..to).cover?(finding.line)
    def range = from == to ? from.to_s : "#{from}–#{to}"
  end
end
