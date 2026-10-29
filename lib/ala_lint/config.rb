module AlaLint
  # The effective settings of one run: the durable `.ala_lint.rb` hash, overridden by the CLI for one
  # run. Each check ends up with a level (:off, :advisory, :scored) and its thresholds.
  class Config
    LEVELS = %i[off advisory scored].freeze
    DEFAULT_PATHS = %w[app lib config/routes.rb].freeze
    DEFAULT_EXCLUDE = [%r{/assets/}, %r{/javascript/}, %r{/views/pwa/}, %r{/channels/application_cable/}].freeze

    attr_reader :root, :paths, :layers, :exclude, :min_score, :identity_models, :require_layers,
                :tier, :preset, :enforce, :disable, :limit, :format, :raw

    def self.load(root, argv_opts = {})
      file = argv_opts[:config] || File.join(root, ".ala_lint.rb")
      raw = File.exist?(file) ? eval(File.read(file), TOPLEVEL_BINDING.dup, file) : {}
      raise ArgumentError, "#{file} must evaluate to a Hash" unless raw.is_a?(Hash)
      new(root, raw, argv_opts)
    end

    def initialize(root, raw = {}, opts = {})
      @root = File.expand_path(root)
      @raw = raw
      @paths = (opts[:paths].to_a.empty? ? Array(raw[:paths] || DEFAULT_PATHS) : opts[:paths]).map { File.expand_path(_1, @root) }
      @layers = opts[:layers] || raw[:layers]
      @exclude = DEFAULT_EXCLUDE + Array(raw[:exclude])
      @min_score = opts[:min_score] || raw[:min_score]
      @identity_models = Array(raw[:identity_models]).map(&:to_s)
      @require_layers = opts[:require_layers] || raw[:require_layers] || false
      @tier = opts[:tier] || :default
      @enforce = Array(opts[:enforce]).map(&:to_sym)
      @disable = Array(opts[:disable]).map(&:to_sym)
      @limit = opts[:limit] || 40
      @format = opts[:format] || :text
      @preset = (opts[:preset] || raw[:preset])&.to_sym
      Checks.preset(@preset) if @preset
      @checks = build_checks(raw[:checks] || {}, opts[:set] || {})
    end

    def level(check) = @checks.fetch(check)[:level]
    def threshold(check, key) = @checks.fetch(check)[key]
    def scored?(check) = level(check) == :scored
    def off?(check) = level(check) == :off
    def layered? = !@layers.nil?

    # What a run changed from the defaults, so the report can say what it skipped.
    def params
      {
        root: @root, paths: @paths.map { relative(_1) }, tier: @tier,
        enforce: @enforce, disabled: Checks::ALL.map(&:name).select { off?(_1) },
        downgraded: Checks::ALL.select { _1.tier == :required && level(_1.name) == :advisory }.map(&:name),
        layers: layered? ? @layers.map { _1[:name] }.join(" > ") : "(none)",
        # a reading (r11.calls) is echoed only when chosen, so a default run's output is unchanged
        thresholds: Checks::ALL.flat_map { |c| c.thresholds.filter_map { |k, d| ["#{c.name}.#{k}", threshold(c.name, k)] unless Checks::CHOICES.key?("#{c.name}.#{k}") && threshold(c.name, k) == d } }.to_h,
        identity_models: @identity_models, min_score: @min_score
      }.merge(@preset ? { preset: @preset } : {}).merge(@conflicts.empty? ? {} : { conflicts: @conflicts })
    end

    def relative(path) = path.start_with?(@root) ? path.delete_prefix(@root).delete_prefix("/") : path

    private

    def build_checks(file_checks, cli_set)
      @conflicts = []
      checks = Checks::ALL.to_h do |c|
        setting = file_checks[c.name] || file_checks[c.name.to_s]
        asked = level_sources(c.name, setting)
        @conflicts << conflict(c.name, asked) if asked.map(&:last).uniq.size > 1
        thresholds = c.thresholds.dup
        thresholds.merge!(setting.slice(*thresholds.keys)) if setting.is_a?(Hash)
        cli_set.each { |k, v| thresholds[k.split(".").last.to_sym] = v if k.start_with?("#{c.name}.") }
        level = asked.empty? ? tier_level(c) : asked.last.last
        [c.name, thresholds.merge(level: level).to_h { |k, v| [k, choice(c.name, k, v)] }]
      end
      @conflicts.sort_by! { _1[:check].to_s }
      checks
    end

    # The level each source asked for, in precedence order, so the last one is the level used and the
    # report can name the ones it overrode.
    def level_sources(check, setting)
      file_level = case setting
                   when Symbol, String then setting
                   when Hash then setting[:level]
                   end
      [
        (["preset #{@preset}", :off] if @preset && !Checks.preset(@preset).include?(check)),
        (["file checks", normalize_level(file_level)] if file_level),
        (["--enforce", :scored] if @enforce.include?(check)),
        (["--disable", :off] if @disable.include?(check))
      ].compact
    end

    def conflict(check, asked)
      { check: check, sources: asked.map { |source, level| { source: source, level: level } },
        winner: asked.last.first, level: asked.last.last }
    end

    def tier_level(check)
      case check.tier
      when :required then :scored
      when :advisory then @tier == :default ? :advisory : :scored
      when :aspirational then @tier == :super_strict ? :scored : :advisory
      else :advisory
      end
    end

    def choice(check, key, value)
      allowed = Checks::CHOICES["#{check}.#{key}"] or return value
      raise ArgumentError, "#{check}.#{key} must be one of #{allowed.join(', ')}, got #{value.inspect}" unless allowed.include?(value.to_s.to_sym)
      value.to_sym
    end

    def normalize_level(value)
      v = value.to_sym
      raise ArgumentError, "check level must be one of #{LEVELS.join(', ')}, got #{value.inspect}" unless LEVELS.include?(v)
      v
    end
  end
end
