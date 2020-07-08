# frozen_string_literal: true

require 'smart_core'

# @api public
# @since 0.1.0
module SmartCore
  # @api public
  # @since 0.1.0
  class Container # rubocop:disable Metrics/ClassLength
    require_relative 'container/version'
    require_relative 'container/errors'
    require_relative 'container/arbitrary_lock'
    require_relative 'container/key_guard'
    require_relative 'container/entities'
    require_relative 'container/definition_dsl'
    require_relative 'container/dependency_compatability'
    require_relative 'container/registry'
    require_relative 'container/registry_builder'
    require_relative 'container/dependency_resolver'
    require_relative 'container/dependency_watcher'
    require_relative 'container/mixin'

    class << self
      # @param initial_container_klass [Class<SmartCore::Container>]
      # @param container_definitions [Block]
      # @return [SmartCore::Container]
      #
      # @api public
      # @since 0.7.0
      def define(initial_container_klass = self, &container_definitions)
        unless initial_container_klass <= SmartCore::Container
          raise(SmartCore::Container::ArgumentError, <<~ERROR_MESSAGE)
            Base class should be a type of SmartCore::Container
          ERROR_MESSAGE
        end

        Class.new(initial_container_klass, &container_definitions).new
      end
    end

    # @since 0.4.0
    include ::Enumerable

    # @since 0.1.0
    include DefinitionDSL

    # @return [SmartCore::Container::Registry]
    #
    # @api private
    # @since 0.1.0
    attr_reader :registry

    # @return [void]
    #
    # @api public
    # @since 0.1.0
    def initialize
      build_registry!
      @access_lock = ArbitraryLock.new
    end

    # @param dependency_name [String, Symbol]
    # @param dependency_definition [Block]
    # @return [void]
    #
    # @api public
    # @sicne 0.1.0
    # @version 0.8.0
    def register(
      dependency_name,
      memoize: SmartCore::Container::Registry::DEFAULT_MEMOIZATION_BEHAVIOR,
      &dependency_definition
    )
      thread_safe do
        registry.register_dependency(dependency_name, memoize: memoize, &dependency_definition)
        watcher.notify(dependency_name)
      end
    end

    # @param namespace_name [String, Symbol]
    # @param dependencies_definition [Block]
    # @return [void]
    #
    # @api public
    # @since 0.1.0
    # @version 0.8.0
    def namespace(namespace_name, &dependencies_definition)
      thread_safe do
        registry.register_namespace(namespace_name, &dependencies_definition)
        watcher.notify(namespace_name)
      end
    end

    # @param dependency_path [String, Symbol]
    # @return [Any]
    #
    # @api public
    # @since 0.1.0
    # @version 0.1.0
    def resolve(dependency_path)
      thread_safe { DependencyResolver.resolve(self, dependency_path) }
    end
    alias_method :[], :resolve

    # @param dependency_path [String, Symbol]
    # @return [Any]
    #
    # @api public
    # @since 0.1.0
    def fetch(dependency_path)
      thread_safe { DependencyResolver.fetch(self, dependency_path) }
    end

    # @return [void]
    #
    # @api public
    # @since 0.1.0
    def freeze!
      thread_safe { registry.freeze! }
    end

    # @return [Boolean]
    #
    # @api public
    # @since 0.1.0
    def frozen?
      thread_safe { registry.frozen? }
    end

    # @return [void]
    #
    # @api public
    # @since 0.1.0
    def reload!
      thread_safe { build_registry! }
    end

    # @option all_variants [Boolean]
    # @return [Array<String>]
    #
    # @api public
    # @since 0.4.0
    def keys(all_variants: SmartCore::Container::Registry::DEFAULT_KEY_EXTRACTION_BEHAVIOUR)
      thread_safe { registry.keys(all_variants: all_variants) }
    end

    # @param key [String, Symbol]
    # @return [Boolean]
    #
    # @api public
    # @since 0.5.0
    def key?(key)
      thread_safe { DependencyResolver.key?(self, key) }
    end

    # @param namespace_path [String, Symbol]
    # @return [Boolean]
    #
    # @api public
    # @since 0.5.0
    def namespace?(namespace_path)
      thread_safe { DependencyResolver.namespace?(self, namespace_path) }
    end

    # @param dependency_path [String, Symbol]
    # @option memoized [NilClass, Boolean]
    # @return [Boolean]
    #
    # @api public
    # @since 0.5.0
    def dependency?(dependency_path, memoized: nil)
      thread_safe { DependencyResolver.dependency?(self, dependency_path, memoized: memoized) }
    end

    # @option yield_all [Boolean]
    # @param block [Block]
    # @yield [dependency_name, dependency_value]
    # @yield_param dependency_name [String]
    # @yield_param dependency_value [Any, SmartCore::Container]
    # @return [Enumerable]
    #
    # @api public
    # @since 0.4.0
    def each_dependency(
      yield_all: SmartCore::Container::Registry::DEFAULT_ITERATION_YIELD_BEHAVIOUR,
      &block
    )
      thread_safe { registry.each_dependency(yield_all: yield_all, &block) }
    end
    alias_method :each, :each_dependency
    alias_method :each_pair, :each_dependency

    # @option resolve_dependencies [Boolean]
    # @return [Hash<String|Symbol,SmartCore::Container::Entities::Base|Any>]
    #
    # @api public
    # @since 0.1.0
    def hash_tree(resolve_dependencies: false)
      thread_safe { registry.hash_tree(resolve_dependencies: resolve_dependencies) }
    end
    alias_method :to_h, :hash_tree
    alias_method :to_hash, :hash_tree

    # @param entity_path [String]
    # @param observer [Block]
    # @yield [dependency]
    # @yieldparam dependency [Any]
    # @return [SmartCore::Container::DependencyWatcher::Observer]
    #
    # @api public
    # @since 0.8.0
    def observe(entity_path, &observer) # TODO: support for pattern-based pathes
      thread_safe { watcher.watch(entity_path, &observer) }
    end
    alias_method :subscribe, :observe

    # @parm observer [SmartCore::Container::DependencyWatcher::Observer]
    # @return [Boolean]
    #
    # @api public
    # @since 0.8.0
    def unobserve(observer)
      thread_safe { watcher.unwatch(observer) }
    end
    alias_method :unsubscribe, :unobserve

    # @param entity_path [String, Symbol]
    # @return [void]
    #
    # @api public
    # @since 0.8.0
    def clear_observers(entity_path = nil) # TODO: support for pattern-based pathes
      thread_safe { watcher.clear_listeners(entity_path) }
    end
    alias_method :clear_listeners, :clear_observers

    private

    # @return [SmartCore::Container::DependencyWatcher]
    #
    # @api private
    # @since 0.8.0
    attr_reader :watcher

    # @return [void]
    #
    # @api private
    # @since 0.1.0
    # @version 0.8.0
    def build_registry!
      @registry = RegistryBuilder.build(self)
      @watcher = SmartCore::Container::DependencyWatcher.new(self)
    end

    # @param block [Block]
    # @return [Any]
    #
    # @api private
    # @since 0.1.0
    def thread_safe(&block)
      @access_lock.thread_safe(&block)
    end
  end
end
