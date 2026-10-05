module AlaLint
  module Rules
    # R2 (no shared mutable state between peers) and R4 (state lives with its owner), in the forms
    # the Ruby edition names: class variables, globals, Thread.current, Current attributes,
    # class-level memoization below the composition, fields reassigned at the top after construction,
    # getters handing out mutated collections, locks, and reaching into another object's ivars.
    class State < Base
      SAFE_GLOBALS = %w[$stdout $stderr $stdin $0 $PROGRAM_NAME $LOAD_PATH $: $; $, $/ $\\ $! $@ $~ $& $1 $2 $3 $4 $5 $6 $7 $8 $9 $_ $DEBUG $VERBOSE].freeze
      MUTATORS = %i[<< push pop shift unshift []= delete delete_if clear concat merge! update store insert reject! select! map! sort! compact! uniq! replace].freeze

      def check
        units.each do |u|
          next if u.template?
          shared_state(u)
          composition_fields(u) if composition?(u) && !u.script?
          leaked_state(u) if below?(u)
        end
      end

      private

      def shared_state(u)
        u.cvars.uniq { _1[0] }.each { |name, line, m| flag(:r2, u, line, "#{u.name}#{method_name(m)} uses class variable #{name}: state every instance and subclass shares (R2, §3.9)") }
        u.gvars.reject { SAFE_GLOBALS.include?(_1[0].to_s) }.uniq { _1[0] }.each { |name, line, m| flag(:r2, u, line, "#{u.name}#{method_name(m)} writes global #{name}: a channel any unit can read (R2)") }
        u.calls.each do |c|
          if c.receiver_kind == :const && c.receiver_name == "Thread" && c.name == :current
            flag(:r2, u, c.line, "#{u.name}#{method_name(c.method)} uses Thread.current: hidden per-thread state shared across calls (R2, R4)")
          elsif c.receiver_kind == :const && c.receiver_name == "Current" && below?(u)
            flag(:r2, u, c.line, "#{u.name}#{method_name(c.method)} reads Current.#{c.name} below the composition: a shared request slot (R2); the composition should pass the value down")
          end
        end
        return if !layered? || bottom?(u) || composition?(u)
        u.methods.select(&:singleton).each do |m|
          m.ivar_writes.each do |w|
            next if w.value_kind == :literal && w.operator.nil?
            flag(:r2, u, w.line, "#{u.name}.#{m.name} keeps class-level state #{w.name}: mutable state shared by every caller (R2, R4, §3.9)")
          end
        end
      end

      # A composition builds and wires; a field it reassigns after construction is state it holds
      # between steps. Landing an output into a field inside a wiring block is one allowed form; a
      # controller handing the view a constant, a parameter or a landed value (`@s = screen`) is the
      # framework's.
      def composition_fields(u)
        landing = %i[new const call_noargs local literal]
        framework = model.framework_subclass?(u)
        u.methods.reject { _1.name == :initialize || _1.singleton }.each do |m|
          m.ivar_writes.each do |w|
            next if w.in_block
            next if w.operator == :"||" && landing.include?(w.value_kind)
            next if framework && w.operator.nil? && landing.include?(w.value_kind)
            flag(:r4, u, w.line, "#{u.name}##{m.name} assigns #{w.name} after construction: the composition keeping state between steps (R4); let the instance that owns it hold it")
          end
        end
      end

      def leaked_state(u)
        mutated = u.calls.select { _1.receiver_kind == :ivar && MUTATORS.include?(_1.name) }.map { _1.receiver_name.delete_prefix("@").to_sym }.to_set
        (u.attr_readers & mutated.to_a).each do |name|
          flag(:r4, u, u.line, "#{u.name} exposes @#{name} with attr_reader and mutates it: a getter handing out live internal state for others to compute on (R4, §3.10)")
        end
        u.calls.each do |c|
          if c.receiver_kind == :const && %w[Mutex Monitor Concurrent::ReentrantReadWriteLock].include?(c.receiver_name) && c.name == :new
            flag(:r4, u, c.line, "#{u.name} creates a #{c.receiver_name}: locks inside a domain class couple it to unknown callers' threading (§3.10.2); decide threads where instances are wired")
          elsif %i[instance_variable_get instance_variable_set].include?(c.name) && !%i[none self].include?(c.receiver_kind) && !bottom?(u)
            flag(:r4, u, c.line, "#{u.name}#{method_name(c.method)} reaches into another object's instance variables (R4, §3.10)")
          end
        end
      end
    end
  end
end
