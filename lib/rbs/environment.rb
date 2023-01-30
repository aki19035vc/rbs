# frozen_string_literal: true

module RBS
  class Environment
    attr_reader :declarations

    attr_reader :class_decls
    attr_reader :interface_decls
    attr_reader :type_alias_decls
    attr_reader :constant_decls
    attr_reader :global_decls
    attr_reader :class_alias_decls

    module ContextUtil
      def calculate_context(decls)
        decls.inject(nil) do |context, decl| #$ Resolver::context
          if (_, last = context)
            last or raise
            [context, last + decl.name]
          else
            [nil, decl.name.absolute!]
          end
        end
      end
    end

    class MultiEntry
      D = _ = Struct.new(:decl, :outer, keyword_init: true) do
        # @implements D[M]

        include ContextUtil

        def context
          @context ||= calculate_context(outer + [decl])
        end
      end

      attr_reader :name
      attr_reader :decls

      def initialize(name:)
        @name = name
        @decls = []
      end

      def insert(decl:, outer:)
        decls << D.new(decl: decl, outer: outer)
        @primary = nil
      end

      def validate_type_params
        unless decls.empty?
          hd_decl, *tl_decls = decls
          raise unless hd_decl

          hd_params = hd_decl.decl.type_params

          tl_decls.each do |tl_decl|
            tl_params = tl_decl.decl.type_params

            unless compatible_params?(hd_params, tl_params)
              raise GenericParameterMismatchError.new(name: name, decl: _ = tl_decl.decl)
            end
          end
        end
      end

      def compatible_params?(ps1, ps2)
        if ps1.size == ps2.size
          ps1 == AST::TypeParam.rename(ps2, new_names: ps1.map(&:name))
        end
      end

      def type_params
        primary.decl.type_params
      end

      def primary
        raise "Not implemented"
      end
    end

    class ModuleEntry < MultiEntry
      def self_types
        decls.flat_map do |d|
          d.decl.self_types
        end.uniq
      end

      def primary
        @primary ||= begin
                       validate_type_params
                       decls.first or raise("decls cannot be empty")
                     end
      end
    end

    class ClassEntry < MultiEntry
      def primary
        @primary ||= begin
                       validate_type_params
                       decls.find {|d| d.decl.super_class } || decls.first or raise("decls cannot be empty")
                     end
      end
    end

    class SingleEntry
      attr_reader :name
      attr_reader :outer
      attr_reader :decl

      def initialize(name:, decl:, outer:)
        @name = name
        @decl = decl
        @outer = outer
      end

      include ContextUtil

      def context
        @context ||= calculate_context(outer)
      end
    end

    class ModuleAliasEntry < SingleEntry
    end

    class ClassAliasEntry < SingleEntry
    end

    class InterfaceEntry < SingleEntry
    end

    class TypeAliasEntry < SingleEntry
    end

    class ConstantEntry < SingleEntry
    end

    class GlobalEntry < SingleEntry
    end

    def initialize
      @buffers = []
      @declarations = []

      @class_decls = {}
      @interface_decls = {}
      @type_alias_decls = {}
      @constant_decls = {}
      @global_decls = {}
      @class_alias_decls = {}
      @normalize_module_name_cache = {}
    end

    def initialize_copy(other)
      @buffers = other.buffers.dup
      @declarations = other.declarations.dup

      @class_decls = other.class_decls.dup
      @interface_decls = other.interface_decls.dup
      @type_alias_decls = other.type_alias_decls.dup
      @constant_decls = other.constant_decls.dup
      @global_decls = other.global_decls.dup
      @class_alias_decls = other.class_alias_decls.dup
    end

    def self.from_loader(loader)
      self.new.tap do |env|
        loader.load(env: env)
      end
    end

    def interface_name?(name)
      interface_decls.key?(name)
    end

    def type_alias_name?(name)
      type_alias_decls.key?(name)
    end

    def module_name?(name)
      class_decls.key?(name) || class_alias_decls.key?(name)
    end

    def type_name?(name)
      interface_name?(name) ||
        type_alias_name?(name) ||
        module_name?(name)
    end

    def constant_name?(name)
      constant_decl?(name) || module_name?(name)
    end

    def constant_decl?(name)
      constant_decls.key?(name)
    end

    def class_decl?(name)
      class_decls[name].is_a?(ClassEntry)
    end

    def module_decl?(name)
      class_decls[name].is_a?(ModuleEntry)
    end

    def module_alias?(name)
      if decl = class_alias_decls[name]
        decl.decl.is_a?(AST::Declarations::ModuleAlias)
      else
        false
      end
    end

    def class_alias?(name)
      if decl = class_alias_decls[name]
        decl.decl.is_a?(AST::Declarations::ClassAlias)
      else
        false
      end
    end

    def class_entry(type_name)
      case
      when (class_entry = class_decls[type_name]).is_a?(ClassEntry)
        class_entry
      when (class_alias = class_alias_decls[type_name]).is_a?(ClassAliasEntry)
        class_alias
      end
    end

    def module_entry(type_name)
      case
      when (module_entry = class_decls[type_name]).is_a?(ModuleEntry)
        module_entry
      when (module_alias = class_alias_decls[type_name]).is_a?(ModuleAliasEntry)
        module_alias
      end
    end

    def normalized_class_entry(type_name)
      entry = class_entry(normalize_module_name(type_name))
      case entry
      when ClassEntry, nil
        entry
      when ClassAliasEntry
        raise
      end
    end

    def normalized_module_entry(type_name)
      entry = module_entry(normalize_module_name(type_name))
      case entry
      when ModuleEntry, nil
        entry
      when ModuleAliasEntry
        raise
      end
    end

    def module_class_entry(type_name)
      class_entry(type_name) || module_entry(type_name)
    end

    def normalized_module_class_entry(type_name)
      normalized_class_entry(type_name) || normalized_module_entry(type_name)
    end

    def constant_entry(type_name)
      class_entry(type_name) || module_entry(type_name) || constant_decls[type_name]
    end

    def normalize_module_name(name)
      normalize_module_name?(name) or name
    end

    def normalize_module_name?(name)
      raise "Class/module name is expected: #{name}" unless name.class?
      name = name.absolute! if name.relative!

      if @normalize_module_name_cache.key?(name)
        case norm = @normalize_module_name_cache[name]
        when TypeName
          return norm
        when nil
          return nil
        when false
          entry = module_class_entry(name)
          case entry
          when ClassAliasEntry, ModuleAliasEntry
            raise CyclicClassAliasDefinitionError.new(entry)
          else
            # This cannot happen because the recursion starts with an alias entry
            raise
          end
        end
      end

      @normalize_module_name_cache[name] = false

      entry = constant_entry(name)
      case entry
      when ClassEntry, ModuleEntry
        @normalize_module_name_cache[name] = entry.name
        entry.name

      when ClassAliasEntry, ModuleAliasEntry
        old_name = entry.decl.old_name
        if old_name.namespace.empty?
          @normalize_module_name_cache[name] = normalize_module_name?(old_name)
        else
          parent = old_name.namespace.to_type_name
          normalized_parent = normalize_module_name(parent)

          @normalize_module_name_cache[name] =
            if normalized_parent == parent
              normalize_module_name?(old_name)
            else
              normalize_module_name?(
                TypeName.new(name: old_name.name, namespace: normalized_parent.to_namespace)
              )
            end
        end

      when ConstantEntry
        raise "#{name} is a constant name"

      else
        @normalize_module_name_cache.delete(name)
        nil
      end
    end

    def insert_decl(decl, outer:, namespace:)
      case decl
      when AST::Declarations::Class, AST::Declarations::Module
        name = decl.name.with_prefix(namespace)

        if cdecl = constant_entry(name)
          if cdecl.is_a?(ConstantEntry) || cdecl.is_a?(ModuleAliasEntry) || cdecl.is_a?(ClassAliasEntry)
            raise DuplicatedDeclarationError.new(name, decl, cdecl.decl)
          end
        end

        unless class_decls.key?(name)
          case decl
          when AST::Declarations::Class
            class_decls[name] ||= ClassEntry.new(name: name)
          when AST::Declarations::Module
            class_decls[name] ||= ModuleEntry.new(name: name)
          end
        end

        existing_entry = class_decls[name]

        case
        when decl.is_a?(AST::Declarations::Module) && existing_entry.is_a?(ModuleEntry)
          existing_entry.insert(decl: decl, outer: outer)
        when decl.is_a?(AST::Declarations::Class) && existing_entry.is_a?(ClassEntry)
          existing_entry.insert(decl: decl, outer: outer)
        else
          raise DuplicatedDeclarationError.new(name, decl, existing_entry.decls[0].decl)
        end

        prefix = outer + [decl]
        ns = name.to_namespace
        decl.each_decl do |d|
          insert_decl(d, outer: prefix, namespace: ns)
        end

      when AST::Declarations::Interface
        name = decl.name.with_prefix(namespace)

        if interface_entry = interface_decls[name]
          DuplicatedDeclarationError.new(name, decl, interface_entry.decl)
        end

        interface_decls[name] = InterfaceEntry.new(name: name, decl: decl, outer: outer)

      when AST::Declarations::TypeAlias
        name = decl.name.with_prefix(namespace)

        if entry = type_alias_decls[name]
          DuplicatedDeclarationError.new(name, decl, entry.decl)
        end

        type_alias_decls[name] = TypeAliasEntry.new(name: name, decl: decl, outer: outer)

      when AST::Declarations::Constant
        name = decl.name.with_prefix(namespace)

        if entry = constant_entry(name)
          case entry
          when ClassAliasEntry, ModuleAliasEntry, ConstantEntry
            raise DuplicatedDeclarationError.new(name, decl, entry.decl)
          when ClassEntry, ModuleEntry
            raise DuplicatedDeclarationError.new(name, decl, *entry.decls.map(&:decl))
          end
        end

        constant_decls[name] = ConstantEntry.new(name: name, decl: decl, outer: outer)

      when AST::Declarations::Global
        if entry = global_decls[decl.name]
          raise DuplicatedDeclarationError.new(name, decl, entry.decl)
        end

        global_decls[decl.name] = GlobalEntry.new(name: decl.name, decl: decl, outer: outer)

      when AST::Declarations::ClassAlias, AST::Declarations::ModuleAlias
        name = decl.new_name.with_prefix(namespace)

        if entry = constant_entry(name)
          case entry
          when ClassAliasEntry, ModuleAliasEntry, ConstantEntry
            raise DuplicatedDeclarationError.new(name, decl, entry.decl)
          when ClassEntry, ModuleEntry
            raise DuplicatedDeclarationError.new(name, decl, *entry.decls.map(&:decl))
          end
        end

        case decl
        when AST::Declarations::ClassAlias
          class_alias_decls[name] = ClassAliasEntry.new(name: name, decl: decl, outer: outer)
        when AST::Declarations::ModuleAlias
          class_alias_decls[name] = ModuleAliasEntry.new(name: name, decl: decl, outer: outer)
        end
      end
    end

    def <<(decl)
      declarations << decl
      insert_decl(decl, outer: [], namespace: Namespace.root)
      self
    end

    def validate_type_params
      class_decls.each_value do |decl|
        decl.primary
      end
    end

    def resolve_type_names(only: nil)
      resolver = Resolver::TypeNameResolver.new(self)
      env = Environment.new

      declarations.each do |decl|
        if only && !only.member?(decl)
          env << decl
        else
          env << resolve_declaration(resolver, decl, outer: [], prefix: Namespace.root)
        end
      end

      env
    end

    def resolver_context(*nesting)
      nesting.inject(nil) {|context, decl| #$ Resolver::context
        append_context(context, decl)
      }
    end

    def append_context(context, decl)
      if (_, last = context)
        last or raise
        [context, last + decl.name]
      else
        [nil, decl.name.absolute!]
      end
    end

    def resolve_declaration(resolver, decl, outer:, prefix:)
      if decl.is_a?(AST::Declarations::Global)
        # @type var decl: AST::Declarations::Global
        return AST::Declarations::Global.new(
          name: decl.name,
          type: absolute_type(resolver, decl.type, context: nil),
          location: decl.location,
          comment: decl.comment
        )
      end

      context = resolver_context(*outer)

      case decl
      when AST::Declarations::Class
        outer_context = context
        inner_context = append_context(outer_context, decl)

        outer_ = outer + [decl]
        prefix_ = prefix + decl.name.to_namespace
        AST::Declarations::Class.new(
          name: decl.name.with_prefix(prefix),
          type_params: resolve_type_params(resolver, decl.type_params, context: inner_context),
          super_class: decl.super_class&.yield_self do |super_class|
            AST::Declarations::Class::Super.new(
              name: absolute_type_name(resolver, super_class.name, context: outer_context),
              args: super_class.args.map {|type| absolute_type(resolver, type, context: outer_context) },
              location: super_class.location
            )
          end,
          members: decl.members.map do |member|
            case member
            when AST::Members::Base
              resolve_member(resolver, member, context: inner_context)
            when AST::Declarations::Base
              resolve_declaration(
                resolver,
                member,
                outer: outer_,
                prefix: prefix_
              )
            else
              raise
            end
          end,
          location: decl.location,
          annotations: decl.annotations,
          comment: decl.comment
        )

      when AST::Declarations::Module
        outer_context = context
        inner_context = append_context(outer_context, decl)

        outer_ = outer + [decl]
        prefix_ = prefix + decl.name.to_namespace
        AST::Declarations::Module.new(
          name: decl.name.with_prefix(prefix),
          type_params: resolve_type_params(resolver, decl.type_params, context: inner_context),
          self_types: decl.self_types.map do |module_self|
            AST::Declarations::Module::Self.new(
              name: absolute_type_name(resolver, module_self.name, context: inner_context),
              args: module_self.args.map {|type| absolute_type(resolver, type, context: inner_context) },
              location: module_self.location
            )
          end,
          members: decl.members.map do |member|
            case member
            when AST::Members::Base
              resolve_member(resolver, member, context: inner_context)
            when AST::Declarations::Base
              resolve_declaration(
                resolver,
                member,
                outer: outer_,
                prefix: prefix_
              )
            else
              raise
            end
          end,
          location: decl.location,
          annotations: decl.annotations,
          comment: decl.comment
        )

      when AST::Declarations::Interface
        AST::Declarations::Interface.new(
          name: decl.name.with_prefix(prefix),
          type_params: resolve_type_params(resolver, decl.type_params, context: context),
          members: decl.members.map do |member|
            resolve_member(resolver, member, context: context)
          end,
          comment: decl.comment,
          location: decl.location,
          annotations: decl.annotations
        )

      when AST::Declarations::TypeAlias
        AST::Declarations::TypeAlias.new(
          name: decl.name.with_prefix(prefix),
          type_params: resolve_type_params(resolver, decl.type_params, context: context),
          type: absolute_type(resolver, decl.type, context: context),
          location: decl.location,
          annotations: decl.annotations,
          comment: decl.comment
        )

      when AST::Declarations::Constant
        AST::Declarations::Constant.new(
          name: decl.name.with_prefix(prefix),
          type: absolute_type(resolver, decl.type, context: context),
          location: decl.location,
          comment: decl.comment
        )

      when AST::Declarations::ClassAlias
        AST::Declarations::ClassAlias.new(
          new_name: decl.new_name.with_prefix(prefix),
          old_name: absolute_type_name(resolver, decl.old_name, context: context),
          location: decl.location,
          comment: decl.comment
        )

      when AST::Declarations::ModuleAlias
        AST::Declarations::ModuleAlias.new(
          new_name: decl.new_name.with_prefix(prefix),
          old_name: absolute_type_name(resolver, decl.old_name, context: context),
          location: decl.location,
          comment: decl.comment
        )
      end
    end

    def resolve_member(resolver, member, context:)
      case member
      when AST::Members::MethodDefinition
        AST::Members::MethodDefinition.new(
          name: member.name,
          kind: member.kind,
          overloads: member.overloads.map do |overload|
            overload.update(
              method_type: resolve_method_type(resolver, overload.method_type, context: context)
            )
          end,
          comment: member.comment,
          overloading: member.overloading?,
          annotations: member.annotations,
          location: member.location,
          visibility: member.visibility
        )
      when AST::Members::AttrAccessor
        AST::Members::AttrAccessor.new(
          name: member.name,
          type: absolute_type(resolver, member.type, context: context),
          kind: member.kind,
          annotations: member.annotations,
          comment: member.comment,
          location: member.location,
          ivar_name: member.ivar_name,
          visibility: member.visibility
        )
      when AST::Members::AttrReader
        AST::Members::AttrReader.new(
          name: member.name,
          type: absolute_type(resolver, member.type, context: context),
          kind: member.kind,
          annotations: member.annotations,
          comment: member.comment,
          location: member.location,
          ivar_name: member.ivar_name,
          visibility: member.visibility
        )
      when AST::Members::AttrWriter
        AST::Members::AttrWriter.new(
          name: member.name,
          type: absolute_type(resolver, member.type, context: context),
          kind: member.kind,
          annotations: member.annotations,
          comment: member.comment,
          location: member.location,
          ivar_name: member.ivar_name,
          visibility: member.visibility
        )
      when AST::Members::InstanceVariable
        AST::Members::InstanceVariable.new(
          name: member.name,
          type: absolute_type(resolver, member.type, context: context),
          comment: member.comment,
          location: member.location
        )
      when AST::Members::ClassInstanceVariable
        AST::Members::ClassInstanceVariable.new(
          name: member.name,
          type: absolute_type(resolver, member.type, context: context),
          comment: member.comment,
          location: member.location
        )
      when AST::Members::ClassVariable
        AST::Members::ClassVariable.new(
          name: member.name,
          type: absolute_type(resolver, member.type, context: context),
          comment: member.comment,
          location: member.location
        )
      when AST::Members::Include
        AST::Members::Include.new(
          name: absolute_type_name(resolver, member.name, context: context),
          args: member.args.map {|type| absolute_type(resolver, type, context: context) },
          comment: member.comment,
          location: member.location,
          annotations: member.annotations
        )
      when AST::Members::Extend
        AST::Members::Extend.new(
          name: absolute_type_name(resolver, member.name, context: context),
          args: member.args.map {|type| absolute_type(resolver, type, context: context) },
          comment: member.comment,
          location: member.location,
          annotations: member.annotations
        )
      when AST::Members::Prepend
        AST::Members::Prepend.new(
          name: absolute_type_name(resolver, member.name, context: context),
          args: member.args.map {|type| absolute_type(resolver, type, context: context) },
          comment: member.comment,
          location: member.location,
          annotations: member.annotations
        )
      else
        member
      end
    end

    def resolve_method_type(resolver, type, context:)
      type.map_type do |ty|
        absolute_type(resolver, ty, context: context)
      end.map_type_bound do |bound|
        _ = absolute_type(resolver, bound, context: context)
      end
    end

    def resolve_type_params(resolver, params, context:)
      params.map do |param|
        param.map_type {|type| _ = absolute_type(resolver, type, context: context) }
      end
    end

    def absolute_type_name(resolver, type_name, context:)
      resolver.resolve(type_name, context: context) || type_name
    end

    def absolute_type(resolver, type, context:)
      type.map_type_name do |name, _, _|
        absolute_type_name(resolver, name, context: context)
      end
    end

    def inspect
      ivars = %i[@declarations @class_decls @class_alias_decls @interface_decls @type_alias_decls @constant_decls @global_decls]
      "\#<RBS::Environment #{ivars.map { |iv| "#{iv}=(#{instance_variable_get(iv).size} items)"}.join(' ')}>"
    end

    def buffers
      buffers_decls.keys.compact
    end

    def buffers_decls
      # @type var hash: Hash[Buffer, Array[AST::Declarations::t]]
      hash = {}

      declarations.each do |decl|
        location = decl.location or next
        (hash[location.buffer] ||= []) << decl
      end

      hash
    end

    def reject
      env = Environment.new

      declarations.each do |decl|
        unless yield(decl)
          env << decl
        end
      end

      env
    end
  end
end
