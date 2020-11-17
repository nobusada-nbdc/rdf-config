require 'rdf-config/sparql'

class RDFConfig
  class SPARQL
    class WhereGenerator < SPARQL
      @@indent_text = '    '
      PROPERTY_PATH_SEP = ' / '.freeze

      class Triple
        attr_reader :subject, :predicate, :object

        def initialize(subject, predicate, object)
          @subject = subject
          @predicate = predicate

          @object = if object.is_a?(Array) && object.size == 1
                      object.first
                    else
                      object
                    end
        end

        def rdf_type?
          %w[a rdf:type].include?(@predicate)
        end

        def to_sparql(indent = '', is_first_triple = true, is_last_triple = true)
          line = if is_first_triple
                   "#{indent}#{subject.to_sparql} "
                 else
                   "#{indent * 2}"
                 end
          line = if rdf_type?
                   if object.has_one_rdf_type?
                     "#{line}a #{object.rdf_type}"
                   else
                     "#{line}a #{object.rdf_type_varname}"
                   end
                 else
                   "#{line}#{predicate} #{object.to_sparql}"
                 end
          line = "#{line} #{is_last_triple ? '.' : ';'}"

          line
        end

        def ==(other)
          @subject == other.subject && @predicate == other.predicate && @object == other.object
        end
      end

      module RDFType
        def has_rdf_type?
          case rdf_types
          when String
            !rdf_types.strip.empty?
          when Array
            !rdf_types.flatten.uniq.first.nil?
          else
            false
          end
        end

        def has_one_rdf_type?
          has_rdf_type? && (rdf_types.instance_of?(String) || rdf_types.size == 1)
        end

        def has_multiple_rdf_types?
          has_rdf_type? && rdf_types.size > 1
        end

        def rdf_types=(rdf_types)
          @rdf_types = case rdf_types
                       when Array
                         rdf_types
                       when String
                         [rdf_types]
                       end
        end

        def rdf_type
          @rdf_types.first
        end
      end

      class Variable
        include RDFType

        attr_reader :name, :rdf_types

        def initialize(name)
          @name = name
        end

        def to_sparql
          case name
          when Array
            name.to_s
          else
            "?#{name}"
          end
        end

        def rdf_type_varname
          "#{to_sparql}Class"
        end

        def ==(other)
          @name == other.name
        end
      end

      class BlankNode
        include RDFType

        attr_reader :predicate_routes, :rdf_types

        def initialize(bnode_id, predicate_routes)
          @bnode_id = bnode_id
          @predicate_routes = predicate_routes
        end

        def name
          "_b#{@bnode_id}"
        end

        def to_sparql
          "_:b#{@bnode_id}"
        end

        def rdf_type_varname
          "?#{name}Class"
        end

        def ==(other)
          name == other.name
        end
      end

      def initialize(config, opts = {})
        super

        if opts.key?(:output_values_line) && opts[:output_values_line] == false
          @output_values_line = false
        else
          @output_values_line = true
        end

        if opts.key?(:indent_text)
          @@indent_text = opts[:indent_text]
        end

        @values_lines = []
        @required_triples = []
        @optional_triples = []

        @variable = {}
        @blank_nodes = []

        @bnode_number = 1
        @depth = 1

        @target_triple = nil

        prepare_sparql_variable_name

        @property_path_map = {}
        variables.each do |variable_name|
          triple = model.find_by_object_name(variable_name)
          next if triple.nil?

          @property_path_map[triple.object_name] = model.property_path(triple.object_name)
          @property_path_map[variable_name] = model.property_path(triple.object_name)
        end
      end

      def generate
        generate_triples
        add_values_lines if @output_values_line

        lines = required_lines
        lines += optional_lines
        lines = ['WHERE {'] + values_lines + lines
        lines << '}'

        lines
      end

      def optional_phrase?(predicate_in_model)
        cardinality = predicate_in_model.cardinality
        cardinality.is_a?(RDFConfig::Model::Cardinality) && (cardinality.min.nil? || cardinality.min == 0)
      end

      private

      def generate_triples
        variables_for_where.each do |variable_name|
          generate_triple_by_variable(variable_name_for_sparql(variable_name))
        end

        @required_triples = generate_rdf_type_triples + @required_triples
      end

      def generate_triple_by_variable(variable_name)
        @target_triple = model.find_by_object_name(variable_name)
        return if @target_triple.nil? || @target_triple.subject.name == variable_name

        if @target_triple.bnode_connecting? && model.same_property_path_exist?(variable_name)
          generate_triples_with_bnode
        else
          generate_triple_without_bnode
        end
      end

      def generate_triple_without_bnode
        object_name = @target_triple.object_name
        return unless @property_path_map.key?(object_name)

        subject = subject_by_object_name(object_name)
        return if !variables.include?(subject.name) && !variables.include?(subject.as_object.values.map(&:name).first)

        property_paths = model.property_path(object_name, subject.name)
        add_triple(Triple.new(subject_instance(subject, subject.types),
                              property_paths.join(PROPERTY_PATH_SEP),
                              variable_instance(@target_triple.object.sparql_varname)),
                   optional_phrase?(@target_triple.predicate))
      end

      def predicate_uri
        predicate = @target_triple.predicates.first
        if @target_triple.subject == @target_triple.object && !predicate.rdf_type?
          "#{predicate.uri}*"
        else
          predicate.uri
        end
      end

      def generate_triples_with_bnode
        bnode_rdf_types = model.bnode_rdf_types(@target_triple)

        if use_property_path?(bnode_rdf_types)
          add_triple(Triple.new(subject_instance(@target_triple.subject),
                                @target_triple.property_path(PROPERTY_PATH_SEP),
                                variable_instance(@target_triple.object_name)),
                     optional_phrase?(@target_triple.predicate)
          )
        else
          generate_triples_with_bnode_rdf_types(bnode_rdf_types)
        end
      end

      def generate_triples_with_bnode_rdf_types(bnode_rdf_types)
        subject = subject_instance(@target_triple.subject, @target_triple.subject.types)
        predicates = @target_triple.predicates

        bnode_predicates = []
        (0...predicates.size - 1).each do |i|
          bnode_predicates << predicates[i]
          rdf_types = bnode_rdf_types[i]
          next if rdf_types.nil?

          object = blank_node(predicates[0..i].map(&:uri), bnode_rdf_types[i])
          add_triple(Triple.new(subject,
                                bnode_predicates.map(&:uri).join(PROPERTY_PATH_SEP),
                                object),
                     false)
          bnode_predicates.clear
          subject = object
          subject.rdf_types = bnode_rdf_types[i]
        end

        object = variable_instance(@target_triple.object_name)
        add_triple(Triple.new(subject,
                              (bnode_predicates + [predicates.last]).map(&:uri).join(PROPERTY_PATH_SEP),
                              object),
                   optional_phrase?(predicates.last))
      end

      def generate_rdf_type_triples
        triples = rdf_type_triples_by_subjects
        subjects = (@required_triples + @optional_triples).map(&:subject).uniq

        (variables - subjects.map(&:name)).each do |variable_name|
          triple = rdf_type_triple_by_variable(variable_name)
          triples << rdf_type_triple_by_variable(variable_name) if triple.is_a?(Triple)
        end

        triples
      end

      def rdf_type_triples_by_subjects
        triples = []

        subjects = (@required_triples + @optional_triples).map(&:subject).uniq
        subjects.each do |subject|
          triples << Triple.new(subject, 'a', subject) if subject.has_rdf_type?
        end

        triples
      end

      def rdf_type_triple_by_variable(variable_name)
        triple_in_model = model.find_by_object_name(variable_name)
        return if triple_in_model.nil?

        rdf_type_triple_by_object(triple_in_model.object, variable_name)
      end

      def rdf_type_triple_by_object(object_in_model, variable_name)
        case object_in_model
        when Model::Subject
          rdf_type_triple_by_subject(object_in_model, variable_name)
        when Model::ValueList
          rdf_type_triple_by_value_list(object_in_model.value, variable_name)
        end
      end

      def rdf_type_triple_by_subject(subject_in_model, variable_name)
        if subject_in_model.types.nil?
          nil
        else
          variable = variable_instance(variable_name)
          variable.rdf_types = subject_in_model.types
          Triple.new(variable, 'a', variable)
        end
      end

      def rdf_type_triple_by_value_list(value_list, variable_name)
        rdf_types = []
        value_list.each do |v|
          next if !v.is_a?(Model::Subject) || v.types.empty?

          rdf_types << v.types
        end

        if rdf_types.empty?
          nil
        else
          variable = variable_instance(variable_name)
          variable.rdf_types = rdf_types.flatten
          Triple.new(variable, 'a', variable)
        end
      end

      def add_values_lines
        add_values_lines_by_parameters
        add_values_lines_for_rdf_type
      end

      def add_values_lines_by_parameters
        parameters.each do |variable_name, value|
          object = model.find_object(variable_name)
          next if object.nil?

          value = "{{#{variable_name}}}" if template?
          value = %("#{value}") if object.is_a?(RDFConfig::Model::Literal) && !object.has_lang_tag? && !object.has_data_type?

          add_values_line(values_line("?#{variable_name}", value))
        end
      end

      def add_values_lines_for_rdf_type
        all_triples.map(&:subject).uniq.each do |subject|
          next unless subject.has_multiple_rdf_types?

          add_values_line(values_line(subject.rdf_type_varname, subject.rdf_types.join(' ')))
        end
      end

      def required_lines
        lines = []

        [Variable, BlankNode].each do |subject_class|
          @required_triples.map(&:subject).select { |subject| subject.is_a?(subject_class) }.uniq.each do |subject|
            lines += lines_by_subject(subject)
          end
        end

        lines
      end

      def lines_by_subject(subject)
        lines = []

        triples = @required_triples.select { |triple| triple.subject == subject }
        return [] if triples.empty?

        triples.each do |triple|
          lines << triple.to_sparql(indent,
                                    triple.object == triples.first.object,
                                    triple.object == triples.last.object)
        end

        lines
      end

      def optional_lines
        lines = []
        @optional_triples.each do |triple|
          lines << "#{indent}OPTIONAL{ #{triple.to_sparql} }"
        end

        lines
      end

      def values_lines
        @values_lines.uniq
      end

      def values_line(variavale_name, value)
        "#{@@indent_text}VALUES #{variavale_name} { #{value} }"
      end

      def use_property_path?(bnode_rdf_types)
        flatten = bnode_rdf_types.flatten
        flatten.uniq.size == 1 && flatten.first.nil?
      end

      def add_triple(triple, is_optional)
        case triple
        when Array
          triple.each do |t|
            add_triple(t, is_optional)
          end
        else
          if is_optional
            @optional_triples << triple unless @optional_triples.include?(triple)
          else
            @required_triples << triple unless @required_triples.include?(triple)
          end
        end
      end

      def subject_in_model_by_variable_instance(variable)
          @model.find_subject(variable.name) ||
            @model.subjects.select { |subject| subject.as_object.values.map(&:name).include?(variable.name) }.first
      end

      def triples_has_subject?(triples, subject)
        !triples.map(&:subject).select { |subj| subj == subject }.empty?
      end

      def subject_instance(subject, rdf_types = nil)
        if subject.is_a?(Array)
          rdf_types = subject
          subject = @target_triple.subject
        end

        if subject.blank_node? && subject.types.size > 1
          blank_node([], subject.types)
        else
          v_inst = variable_instance(variable_name_for_sparql(subject.name))
          v_inst.rdf_types = rdf_types if !rdf_types.nil?

          v_inst
        end
      end

      def variable_instance(variable_name)
        if @variable.key?(variable_name)
          @variable[variable_name]
        else
          add_variable(variable_name)
        end
      end

      def add_variable(variable_name)
        @variable[variable_name] = Variable.new(variable_name)
      end

      def blank_node(predicate_routes, rdf_types)
        bnodes = @blank_nodes.select { |bnode| bnode.predicate_routes == predicate_routes && bnode.rdf_types == rdf_types }
        if bnodes.empty?
          add_blank_node(predicate_routes, rdf_types)
        else
          bnodes.first
        end
      end

      def add_blank_node(predicate_routes, rdf_types)
        bnode = BlankNode.new(@bnode_number, predicate_routes)
        bnode.rdf_types = rdf_types
        @blank_nodes << bnode
        @bnode_number += 1

        bnode
      end

      def add_values_line(line)
        @values_lines << line
      end

      def all_triples
        @required_triples + @optional_triples
      end

      def template?
        @opts.key?(:template) && @opts[:template] == true
      end

      def indent(depth_increment = 0)
        "#{@@indent_text * (@depth + depth_increment)}"
      end

      def hidden_variables
        variable_names = []
        variables.each do |variable_name|
          variable_names += model.parent_variables(variable_name)
        end

        variable_names.flatten.uniq
      end

      def variables_for_where
        variables
      end

      def subject_by_object_name(object_name)
        object_name_for_subject = nil
        model.parent_variables(object_name).reverse.each do |variable_name|
          object_name_for_subject = variable_name
          break if variables.include?(variable_name)

          triple = model.find_by_object_name(variable_name)
          break if !triple.nil? && variables.include?(triple.object.name)
        end

        if object_name_for_subject.nil?
          subject = model.subjects.first
        else
          subject = model.find_object(object_name_for_subject)
          subject = model.subjects.first if subject.nil?
        end

        subject
      end
    end
  end
end
