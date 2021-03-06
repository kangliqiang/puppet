# The scope class, which handles storing and retrieving variables and types and
# such.
require 'forwardable'

require 'puppet/parser'
require 'puppet/parser/templatewrapper'

require 'puppet/resource/type_collection_helper'
require 'puppet/util/methodhelper'

# This class is part of the internal parser/evaluator/compiler functionality of Puppet.
# It is passed between the various classes that participate in evaluation.
# None of its methods are API except those that are clearly marked as such.
#
# @api public
class Puppet::Parser::Scope
  extend Forwardable
  include Puppet::Util::MethodHelper

  include Puppet::Resource::TypeCollectionHelper
  require 'puppet/parser/resource'

  AST = Puppet::Parser::AST

  Puppet::Util.logmethods(self)

  include Puppet::Util::Errors
  attr_accessor :source, :resource
  attr_accessor :compiler
  attr_accessor :parent
  attr_reader :namespaces

  # Add some alias methods that forward to the compiler, since we reference
  # them frequently enough to justify the extra method call.
  def_delegators :compiler, :catalog, :environment


  # Abstract base class for LocalScope and MatchScope
  #
  class Ephemeral

    attr_reader :parent

    def initialize(parent = nil)
      @parent = parent
    end

    def is_local_scope?
      false
    end

    def [](name)
      if @parent
        @parent[name]
      end
    end

    def include?(name)
      (@parent and @parent.include?(name))
    end

    def bound?(name)
      false
    end

    def add_entries_to(target = {})
      @parent.add_entries_to(target) unless @parent.nil?
      # do not include match data ($0-$n)
      target
    end
  end

  class LocalScope < Ephemeral

    def initialize(parent=nil)
      super parent
      @symbols = {}
    end

    def [](name)
      if @symbols.include?(name)
        @symbols[name]
      else
        super
      end
    end

    def is_local_scope?
      true
    end

    def []=(name, value)
      @symbols[name] = value
    end

    def include?(name)
      bound?(name) || super
    end

    def delete(name)
      @symbols.delete(name)
    end

    def bound?(name)
      @symbols.include?(name)
    end

    def add_entries_to(target = {})
      super
      @symbols.each do |k, v|
        if v == :undef
          target.delete(k)
        else
          target[ k ] = v
        end
      end
      target
    end
  end

  class MatchScope < Ephemeral

    attr_accessor :match_data

    def initialize(parent = nil, match_data = nil)
      super parent
      @match_data = match_data
    end

    def is_local_scope?
      false
    end

    def [](name)
      if bound?(name)
        @match_data[name.to_i]
      else
        super
      end
    end

    def include?(name)
      bound?(name) or super
    end

    def bound?(name)
      # A "match variables" scope reports all numeric variables to be bound if the scope has
      # match_data. Without match data the scope is transparent.
      #
      @match_data && name =~ /^\d+$/
    end

    def []=(name, value)
      # TODO: Bad choice of exception
      raise Puppet::ParseError, "Numerical variables cannot be changed. Attempt to set $#{name}"
    end

    def delete(name)
      # TODO: Bad choice of exception
      raise Puppet::ParseError, "Numerical variables cannot be deleted: Attempt to delete: $#{name}"
    end

    def add_entries_to(target = {})
      # do not include match data ($0-$n)
      super
    end

  end

  # Returns true if the variable of the given name has a non nil value.
  # TODO: This has vague semantics - does the variable exist or not?
  #       use ['name'] to get nil or value, and if nil check with exist?('name')
  #       this include? is only useful because of checking against the boolean value false.
  #
  def include?(name)
    ! self[name].nil?
  end

  # Returns true if the variable of the given name is set to any value (including nil)
  #
  def exist?(name)
    next_scope = inherited_scope || enclosing_scope
    effective_symtable(true).include?(name) || next_scope && next_scope.exist?(name)
  end

  # Returns true if the given name is bound in the current (most nested) scope for assignments.
  #
  def bound?(name)
    # Do not look in ephemeral (match scope), the semantics is to answer if an assignable variable is bound
    effective_symtable(false).bound?(name)
  end

  # Is the value true?  This allows us to control the definition of truth
  # in one place.
  def self.true?(value)
    case value
    when ''
      false
    when :undef
      false
    else
      !!value
    end
  end

  # Coerce value to a number, or return `nil` if it isn't one.
  def self.number?(value)
    case value
    when Numeric
      value
    when /^-?\d+(:?\.\d+|(:?\.\d+)?e\d+)$/
      value.to_f
    when /^0x[0-9a-f]+$/i
      value.to_i(16)
    when /^0[0-7]+$/
      value.to_i(8)
    when /^-?\d+$/
      value.to_i
    else
      nil
    end
  end

  # Add to our list of namespaces.
  def add_namespace(ns)
    return false if @namespaces.include?(ns)
    if @namespaces == [""]
      @namespaces = [ns]
    else
      @namespaces << ns
    end
  end

  def find_hostclass(name, options = {})
    known_resource_types.find_hostclass(namespaces, name, options)
  end

  def find_definition(name)
    known_resource_types.find_definition(namespaces, name)
  end

  # This just delegates directly.
  def_delegator :compiler, :findresource

  # Initialize our new scope.  Defaults to having no parent.
  def initialize(compiler, options = {})
    if compiler.is_a? Puppet::Parser::Compiler
      self.compiler = compiler
    else
      raise Puppet::DevError, "you must pass a compiler instance to a new scope object"
    end

    if n = options.delete(:namespace)
      @namespaces = [n]
    else
      @namespaces = [""]
    end

    raise Puppet::DevError, "compiler passed in options" if options.include? :compiler
    set_options(options)

    extend_with_functions_module

    # The symbol table for this scope.  This is where we store variables.
    #    @symtable = Ephemeral.new(nil, true)
    @symtable = LocalScope.new(nil)

    @ephemeral = [ MatchScope.new(@symtable, nil) ]

    # All of the defaults set for types.  It's a hash of hashes,
    # with the first key being the type, then the second key being
    # the parameter.
    @defaults = Hash.new { |dhash,type|
      dhash[type] = {}
    }

    # The table for storing class singletons.  This will only actually
    # be used by top scopes and node scopes.
    @class_scopes = {}
  end

  # Store the fact that we've evaluated a class, and store a reference to
  # the scope in which it was evaluated, so that we can look it up later.
  def class_set(name, scope)
    if parent
      parent.class_set(name, scope)
    else
      @class_scopes[name] = scope
    end
  end

  # Return the scope associated with a class.  This is just here so
  # that subclasses can set their parent scopes to be the scope of
  # their parent class, and it's also used when looking up qualified
  # variables.
  def class_scope(klass)
    # They might pass in either the class or class name
    k = klass.respond_to?(:name) ? klass.name : klass
    @class_scopes[k] || (parent && parent.class_scope(k))
  end

  # Collect all of the defaults set at any higher scopes.
  # This is a different type of lookup because it's additive --
  # it collects all of the defaults, with defaults in closer scopes
  # overriding those in later scopes.
  def lookupdefaults(type)
    values = {}

    # first collect the values from the parents
    if parent
      parent.lookupdefaults(type).each { |var,value|
        values[var] = value
      }
    end

    # then override them with any current values
    # this should probably be done differently
    if @defaults.include?(type)
      @defaults[type].each { |var,value|
        values[var] = value
      }
    end

    values
  end

  # Look up a defined type.
  def lookuptype(name)
    find_definition(name) || find_hostclass(name)
  end

  def undef_as(x,v)
    if v.nil? or v == :undef
      x
    else
      v
    end
  end

  # Lookup a variable within this scope using the Puppet language's
  # scoping rules. Variables can be qualified using just as in a
  # manifest.
  #
  # @param [String] name the variable name to lookup
  #
  # @return Object the value of the variable, or nil if it's not found
  #
  # @api public
  def lookupvar(name, options = {})
    unless name.is_a? String
      raise Puppet::ParseError, "Scope variable name #{name.inspect} is a #{name.class}, not a string"
    end

    table = @ephemeral.last

    if name =~ /^(.*)::(.+)$/
      class_name = $1
      variable_name = $2
      lookup_qualified_variable(class_name, variable_name, options)

    # TODO: optimize with an assoc instead, this searches through scopes twice for a hit
    elsif table.include?(name)
      table[name]
    else
      next_scope = inherited_scope || enclosing_scope
      if next_scope
        next_scope.lookupvar(name, options)
      else
        variable_not_found(name)
      end
    end
  end

  def variable_not_found(name, reason=nil)
    if Puppet[:strict_variables]
      if Puppet[:evaluator] == 'future' && Puppet[:parser] == 'future'
        throw :undefined_variable
      else
        reason_msg = reason.nil? ? '' : "; #{reason}"
        raise Puppet::ParseError, "Undefined variable #{name.inspect}#{reason_msg}"
      end
    else
      nil
    end
  end
  # Retrieves the variable value assigned to the name given as an argument. The name must be a String,
  # and namespace can be qualified with '::'. The value is looked up in this scope, its parent scopes,
  # or in a specific visible named scope.
  #
  # @param varname [String] the name of the variable (may be a qualified name using `(ns'::')*varname`
  # @param options [Hash] Additional options, not part of api.
  # @return [Object] the value assigned to the given varname
  # @see #[]=
  # @api public
  #
  def [](varname, options={})
    lookupvar(varname, options)
  end

  # The scope of the inherited thing of this scope's resource. This could
  # either be a node that was inherited or the class.
  #
  # @return [Puppet::Parser::Scope] The scope or nil if there is not an inherited scope
  def inherited_scope
    if has_inherited_class?
      qualified_scope(resource.resource_type.parent)
    else
      nil
    end
  end

  # The enclosing scope (topscope or nodescope) of this scope.
  # The enclosing scopes are produced when a class or define is included at
  # some point. The parent scope of the included class or define becomes the
  # scope in which it was included. The chain of parent scopes is followed
  # until a node scope or the topscope is found
  #
  # @return [Puppet::Parser::Scope] The scope or nil if there is no enclosing scope
  def enclosing_scope
    if has_enclosing_scope?
      if parent.is_topscope? or parent.is_nodescope?
        parent
      else
        parent.enclosing_scope
      end
    else
      nil
    end
  end

  def is_classscope?
    resource and resource.type == "Class"
  end

  def is_nodescope?
    resource and resource.type == "Node"
  end

  def is_topscope?
    compiler and self == compiler.topscope
  end

  def lookup_qualified_variable(class_name, variable_name, position)
    begin
      if lookup_as_local_name?(class_name, variable_name)
        self[variable_name]
      else
        qualified_scope(class_name).lookupvar(variable_name, position)
      end
    rescue RuntimeError => e
      unless Puppet[:strict_variables]
        # Do not issue warning if strict variables are on, as an error will be raised by variable_not_found
        location = if position[:lineproc]
                     " at #{position[:lineproc].call}"
                   elsif position[:file] && position[:line]
                     " at #{position[:file]}:#{position[:line]}"
                   else
                     ""
                   end
        warning "Could not look up qualified variable '#{class_name}::#{variable_name}'; #{e.message}#{location}"
      end
      variable_not_found("#{class_name}::#{variable_name}", e.message)
    end
  end

  # Handles the special case of looking up fully qualified variable in not yet evaluated top scope
  # This is ok if the lookup request originated in topscope (this happens when evaluating
  # bindings; using the top scope to provide the values for facts.
  # @param class_name [String] the classname part of a variable name, may be special ""
  # @param variable_name [String] the variable name without the absolute leading '::'
  # @return [Boolean] true if the given variable name should be looked up directly in this scope
  #
  def lookup_as_local_name?(class_name, variable_name)
    # not a local if name has more than one segment
    return nil if variable_name =~ /::/
    # partial only if the class for "" cannot be found
    return nil unless class_name == "" && klass = find_hostclass(class_name) && class_scope(klass).nil?
    is_topscope?
  end

  def has_inherited_class?
    is_classscope? and resource.resource_type.parent
  end
  private :has_inherited_class?

  def has_enclosing_scope?
    not parent.nil?
  end
  private :has_enclosing_scope?

  def qualified_scope(classname)
    raise "class #{classname} could not be found"     unless klass = find_hostclass(classname)
    raise "class #{classname} has not been evaluated" unless kscope = class_scope(klass)
    kscope
  end
  private :qualified_scope

  # Returns a Hash containing all variables and their values, optionally (and
  # by default) including the values defined in parent. Local values
  # shadow parent values. Ephemeral scopes for match results ($0 - $n) are not included.
  #
  def to_hash(recursive = true)
    if recursive and parent
      target = parent.to_hash(recursive)
    else
      target = Hash.new
    end

    # add all local scopes
    @ephemeral.last.add_entries_to(target)
    target
  end

  def namespaces
    @namespaces.dup
  end

  # Create a new scope and set these options.
  def newscope(options = {})
    compiler.newscope(self, options)
  end

  def parent_module_name
    return nil unless @parent
    return nil unless @parent.source
    @parent.source.module_name
  end

  # Set defaults for a type.  The typename should already be downcased,
  # so that the syntax is isolated.  We don't do any kind of type-checking
  # here; instead we let the resource do it when the defaults are used.
  def define_settings(type, params)
    table = @defaults[type]

    # if we got a single param, it'll be in its own array
    params = [params] unless params.is_a?(Array)

    params.each { |param|
      if table.include?(param.name)
        raise Puppet::ParseError.new("Default already defined for #{type} { #{param.name} }; cannot redefine", param.line, param.file)
      end
      table[param.name] = param
    }
  end

  RESERVED_VARIABLE_NAMES = ['trusted'].freeze

  # Set a variable in the current scope.  This will override settings
  # in scopes above, but will not allow variables in the current scope
  # to be reassigned.
  #   It's preferred that you use self[]= instead of this; only use this
  # when you need to set options.
  def setvar(name, value, options = {})
    if name =~ /^[0-9]+$/
      raise Puppet::ParseError.new("Cannot assign to a numeric match result variable '$#{name}'") # unless options[:ephemeral]
    end
    unless name.is_a? String
      raise Puppet::ParseError, "Scope variable name #{name.inspect} is a #{name.class}, not a string"
    end

    # Check for reserved variable names
    if Puppet[:trusted_node_data] && !options[:privileged] && RESERVED_VARIABLE_NAMES.include?(name)
      raise Puppet::ParseError, "Attempt to assign to a reserved variable name: '#{name}'"
    end

    table = effective_symtable options[:ephemeral]
    if table.bound?(name)
      if options[:append]
        error = Puppet::ParseError.new("Cannot append, variable #{name} is defined in this scope")
      else
        error = Puppet::ParseError.new("Cannot reassign variable #{name}")
      end
      error.file = options[:file] if options[:file]
      error.line = options[:line] if options[:line]
      raise error
    end

    if options[:append]
      table[name] = append_value(undef_as('', self[name]), value)
    else
      table[name] = value
    end
    table[name]
  end

  def set_trusted(hash)
    setvar('trusted', deep_freeze(hash), :privileged => true)
  end

  # Deeply freezes the given object. The object and its content must be of the types:
  # Array, Hash, Numeric, Boolean, Symbol, Regexp, NilClass, or String. All other types raises an Error.
  # (i.e. if they are assignable to Puppet::Pops::Types::Data type).
  #
  def deep_freeze(object)
    case object
    when Hash
      object.each {|k, v| deep_freeze(k); deep_freeze(v) }
    when NilClass
      # do nothing
    when String
      object.freeze
    else
      raise Puppet::Error, "Unsupported data type: '#{object.class}"
    end
    object
  end
  private :deep_freeze

  # Return the effective "table" for setting variables.
  # This method returns the first ephemeral "table" that acts as a local scope, or this
  # scope's symtable. If the parameter `use_ephemeral` is true, the "top most" ephemeral "table"
  # will be returned (irrespective of it being a match scope or a local scope).
  #
  # @param use_ephemeral [Boolean] whether the top most ephemeral (of any kind) should be used or not
  def effective_symtable use_ephemeral
    s = @ephemeral.last
    return s || @symtable if use_ephemeral

    # Why check if ephemeral is a Hash ??? Not needed, a hash cannot be a parent scope ???
    while s && !(s.is_a?(Hash) || s.is_local_scope?())
      s = s.parent
    end
    s ? s : @symtable
  end

  # Sets the variable value of the name given as an argument to the given value. The value is
  # set in the current scope and may shadow a variable with the same name in a visible outer scope.
  # It is illegal to re-assign a variable in the same scope. It is illegal to set a variable in some other
  # scope/namespace than the scope passed to a method.
  #
  # @param varname [String] The variable name to which the value is assigned. Must not contain `::`
  # @param value [String] The value to assign to the given variable name.
  # @param options [Hash] Additional options, not part of api.
  #
  # @api public
  #
  def []=(varname, value, options = {})
    setvar(varname, value, options = {})
  end

  def append_value(bound_value, new_value)
    case new_value
    when Array
      bound_value + new_value
    when Hash
      bound_value.merge(new_value)
    else
      if bound_value.is_a?(Hash)
        raise ArgumentError, "Trying to append to a hash with something which is not a hash is unsupported"
      end
      bound_value + new_value
    end
  end
  private :append_value

  # Return the tags associated with this scope.
  def_delegator :resource, :tags

  # Used mainly for logging
  def to_s
    "Scope(#{@resource})"
  end

  # remove ephemeral scope up to level
  # TODO: Who uses :all ? Remove ??
  #
  def unset_ephemeral_var(level=:all)
    if level == :all
      @ephemeral = [ MatchScope.new(@symtable, nil)]
    else
      @ephemeral.pop(@ephemeral.size - level)
    end
  end

  def ephemeral_level
    @ephemeral.size
  end

  # TODO: Who calls this?
  def new_ephemeral(local_scope = false)
    if local_scope
      @ephemeral.push(LocalScope.new(@ephemeral.last))
    else
      @ephemeral.push(MatchScope.new(@ephemeral.last, nil))
    end
  end

  # Sets match data in the most nested scope (which always is a MatchScope), it clobbers match data already set there
  #
  def set_match_data(match_data)
    @ephemeral.last.match_data = match_data
  end

  # Nests a match data scope
  def new_match_scope(match_data)
    @ephemeral.push(MatchScope.new(@ephemeral.last, match_data))
  end

  def ephemeral_from(match, file = nil, line = nil)
    case match
    when Hash
      # Create local scope ephemeral and set all values from hash
      new_ephemeral(true)
      match.each {|k,v| setvar(k, v, :file => file, :line => line, :ephemeral => true) }
      # Must always have an inner match data scope (that starts out as transparent)
      # In 3x slightly wasteful, since a new nested scope is created for a match 
      # (TODO: Fix that problem)
      new_ephemeral(false)
    else
      raise(ArgumentError,"Invalid regex match data. Got a #{match.class}") unless match.is_a?(MatchData)
      # Create a match ephemeral and set values from match data
      new_match_scope(match)
    end
  end

  def find_resource_type(type)
    # It still works fine without the type == 'class' short-cut, but it is a lot slower.
    return nil if ["class", "node"].include? type.to_s.downcase
    find_builtin_resource_type(type) || find_defined_resource_type(type)
  end

  def find_builtin_resource_type(type)
    Puppet::Type.type(type.to_s.downcase.to_sym)
  end

  def find_defined_resource_type(type)
    known_resource_types.find_definition(namespaces, type.to_s.downcase)
  end


  def method_missing(method, *args, &block)
    method.to_s =~ /^function_(.*)$/
    name = $1
    super unless name
    super unless Puppet::Parser::Functions.function(name)
    # In odd circumstances, this might not end up defined by the previous
    # method, so we might as well be certain.
    if respond_to? method
      send(method, *args)
    else
      raise Puppet::DevError, "Function #{name} not defined despite being loaded!"
    end
  end

  def resolve_type_and_titles(type, titles)
    raise ArgumentError, "titles must be an array" unless titles.is_a?(Array)

    case type.downcase
    when "class"
      # resolve the titles
      titles = titles.collect do |a_title|
        hostclass = find_hostclass(a_title)
        hostclass ?  hostclass.name : a_title
      end
    when "node"
      # no-op
    else
      # resolve the type
      resource_type = find_resource_type(type)
      type = resource_type.name if resource_type
    end

    return [type, titles]
  end

  private

  def extend_with_functions_module
    extend Puppet::Parser::Functions.environment_module(Puppet::Node::Environment.root)
    extend Puppet::Parser::Functions.environment_module(environment) if environment != Puppet::Node::Environment.root
  end
end
