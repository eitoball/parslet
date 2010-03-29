require 'stringio'

module Parslet
  module Matchers
    class ParseFailed < Exception; end
    
    class Base
      def parse(io)
        if io.respond_to? :to_str
          io = StringIO.new(io)
        end
        
        result = apply(io)
        
        error(io, "Don't know what to do with #{io.string[io.pos,100]}") unless io.eof?
        return flatten(result)
      end
      
      def apply(io)
        # p [:start, self, io.string[io.pos, 10]]
        
        old_pos = io.pos
        
        # p [:try, self, io.string[io.pos, 20]]
        begin
          r = try(io)
          # p [:return_from, self, r]
          return r
        rescue ParseFailed => ex
          # p [:failing, self, io.string[io.pos, 20]]
          io.pos = old_pos; raise ex
        end
      end
      
      def repeat(min=0)
        Repetition.new(self, min, nil)
      end
      def maybe
        Repetition.new(self, 0, 1)
      end
      def >>(parslet)
        Sequence.new(self, parslet)
      end
      def /(parslet)
        Alternative.new(self, parslet)
      end
      def absnt?
        Lookahead.new(self, false)
      end
      def prsnt?
        Lookahead.new(self, true)
      end
      def as(name)
        Named.new(self, name)
      end

      def flatten(value)
        # Passes through everything that isn't an array of things
        return value unless value.instance_of? Array

        # Extracts the s-expression tag
        tag, *tail = value
        
        # Merges arrays:
        result = tail.
          map { |e| flatten(e) }            # first flatten each element
          
        if tag == :sequence
          result.inject('') { |r, e|        # and then merge flat elements
            case [r, e].map { |o| o.class }
              when [Hash, Hash]
                warn_about_duplicate_keys(r, e)
                r.merge(e)
              when [String, String]
                r << e
            else
              if r.instance_of? Hash
                r   # Ignore e, since its not a hash we can merge
              else
                e   # Whatever e is at this point, we keep it
              end
            end
          }
        else
          if result.any? { |e| e.instance_of?(Hash) }
            result.select { |e| e.instance_of?(Hash) }
          else
            result.inject('') { |s,e| s<<e }
          end
        end
      end

      def complex?; false; end
    private    
      def error(io, str)
        pre = io.string[0..io.pos]
        lines = Array(pre.lines)
        pos   = lines.last.length
        raise ParseFailed, "#{str} at line #{lines.count} char #{pos}."
      end
      def warn_about_duplicate_keys(h1, h2)
        d = h1.keys & h2.keys
        unless d.empty?
          warn "Duplicate subtrees while merging result of \n  #{self.inspect}\nonly the values"+
               " of the latter will be kept. (keys: #{d.inspect})"
        end
      end
    end
    
    class Named < Base
      attr_reader :parslet, :name
      def initialize(parslet, name)
        @parslet, @name = parslet, name
      end
      
      def apply(io)
        value = parslet.apply(io)
        
        produce_return_value value
      end
      
      def inspect
        "#{name}:#{parslet.inspect}"
      end
    private
      def produce_return_value(val)  
        { name => flatten(val) }
      end
    end
    
    class Lookahead < Base
      attr_reader :positive
      attr_reader :bound_parslet
      
      def initialize(bound_parslet, positive=true)
        # Model positive and negative lookahead by testing this flag.
        @positive = positive
        @bound_parslet = bound_parslet
      end
      
      def try(io)
        pos = io.pos
        begin
          bound_parslet.apply(io)
        rescue ParseFailed 
          return fail(io)
        ensure 
          io.pos = pos
        end
        return success(io)
      end
      
      def fail(io)
        if positive
          error(io, "lookahead: #{bound_parslet.inspect} didn't match, but should have")
        else
          # TODO: Squash this down to nothing? Return value handling here...
          return nil
        end
      end
      def success(io)
        if positive
          return nil  # see above, TODO
        else
          error(
            io, 
            "negative lookahead: #{bound_parslet.inspect} matched, but shouldn't have")
        end
      end

      def inspect
        char = positive ? '&' : '!'
        
        "#{char}#{bound_parslet.inspect}"
      end
    end

    class Alternative < Base
      attr_reader :alternatives
      def initialize(*alternatives)
        @alternatives = alternatives
      end
      
      def /(parslet)
        @alternatives << parslet
        self
      end
      
      def try(io)
        alternatives.each { |a|
          begin
            return a.apply(io)
          rescue ParseFailed => ex
          end
        }
        error(io, "Expected one of #{alternatives.inspect}.")
      end

      def complex?; true; end
      def inspect
        alternatives.map { |a| a.inspect }.join(' / ')
      end
    end
    
    class Sequence < Base
      attr_reader :parslets
      def initialize(*parslets)
        @parslets = parslets
      end
      
      def >>(parslet)
        @parslets << parslet
        self
      end
      
      def try(io)
        [:sequence]+parslets.map { |p| p.apply(io) }
      end
      
      def inspect
        '('+ parslets.map { |p| p.inspect }.join(' ') + ')'
      end
    end
    
    class Repetition < Base
      attr_reader :min, :max, :parslet
      def initialize(parslet, min, max)
        @parslet = parslet
        @min, @max = min, max
      end
      
      def try(io)
        occ = 0
        result = [:repetition]
        loop do
          begin
            result << parslet.apply(io)
            occ += 1

            # If we're not greedy (max is defined), check if that has been 
            # reached. 
            return result if max && occ==max
          rescue ParseFailed => ex
            # Greedy matcher has produced a failure. Check if occ (which will
            # contain the number of sucesses) is in {min, max}.
            # p [:repetition, occ, min, max]
            raise ex if occ < min
            raise ex if max && occ > max
            return result
          end
        end
      end
      
      def inspect
        minmax = "{#{min}, #{max}}"
        minmax = '?' if min == 0 && max == 1

        if parslet.complex?
          "("+ parslet.inspect + ")" + minmax
        else
          parslet.inspect + minmax
        end
      end
    end

    class Re < Base
      attr_reader :match
      def initialize(match)
        @match = match
      end

      def try(io)
        r = Regexp.new(match, Regexp::MULTILINE)
        s = io.read(1)
        error(io, "Premature end of input") unless s
        error(io, "Failed to match #{match}") unless s.match(r)
        return s
      end

      def inspect
        match
      end
    end
    
    class Str < Base
      attr_reader :str
      def initialize(str)
        @str = str
      end
      
      def try(io)
        old_pos = io.pos
        s = io.read(str.size)
        raise(ParseFailed, "Premature end of input.") unless s && s.size==str.size
        raise(ParseFailed, "Expected #{str.inspect}, but got #{s.inspect}") unless s==str
        return s
      end
      
      def inspect
        "'#{str}'"
      end
    end

    class Entity < Base
      attr_reader :name, :block
      def initialize(name, block)
        super()
        
        @name = name
        @block = block
      end

      def try(io)
        parslet.apply(io)
      end
      
      def parslet
        @parslet ||= block.call
      end

      def inspect
        name
      end
    end
  end

  def named(name, &block)
    Matchers::Entity.new(name, block)
  end
  def match(obj)
    Matchers::Re.new(obj)
  end
  def str(str)
    Matchers::Str.new(str)
  end
  def any
    Matchers::Re.new('.')
  end
end

