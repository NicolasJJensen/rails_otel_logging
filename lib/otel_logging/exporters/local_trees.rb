# frozen_string_literal: true

module OtelLogging
  module Exporters
    module LocalTrees
      def span_key(span)
        [span.context.hex_trace_id, span.context.hex_span_id]
      end

      def register_tree(span)
        @tree_members ||= {}
        @span_trees ||= {}
        key = span_key(span)
        parent = [key.first, span.parent_span_id.unpack1('H*')]
        tree = @span_trees[parent] || key
        @span_trees[key] = tree
        (@tree_members[tree] ||= []) << key
        @open_spans ||= Hash.new(0)
        @finished_roots ||= {}
        @open_spans[tree] += 1
        tree
      end

      def tree_for(span)
        @span_trees&.fetch(span_key(span), nil)
      end

      def tree_finished?(span)
        tree = tree_for(span)
        return false unless tree

        @open_spans[tree] -= 1
        @finished_roots[tree] = true if span_key(span) == tree
        @finished_roots[tree] && @open_spans[tree].zero?
      end

      def remove_tree(tree)
        @open_spans&.delete(tree)
        @finished_roots&.delete(tree)
        @tree_members&.delete(tree)&.each { |key| @span_trees.delete(key) }
      end

      def clear_trees
        @open_spans&.clear
        @finished_roots&.clear
        @tree_members&.clear
        @span_trees&.clear
      end
    end
  end
end
