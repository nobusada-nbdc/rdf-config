class RDFConfig
  class Model
    class Validator
      attr_reader :errors

      def initialize(model, config)
        @model = model
        @config = config

        @errors = []
        @undefined_prefixes = []
        @num_subject_name = {}
        @num_variable = {}
      end

      def validate
        @model.subjects.each do |subject|
          add_subject_name(subject.name)
          validate_subject(subject)
        end

        validate_subject_name
        validate_variable
      end

      def error?
        !@errors.empty?
      end

      private

      def validate_subject(subject)
        validate_resource_class(subject)
        validate_prefix(subject.value)
        subject.predicates.each do |predicate|
          validate_predicate(predicate)
        end
      end

      def validate_subject_name
        @num_subject_name.select { |subject_name, num_subject_name| num_subject_name > 1 }.keys.each do |subject_name|
          add_error(%/Duplicate subject name (#{subject_name}) in model.yaml file./)
        end
      end

      def validate_predicate(predicate)
        validate_prefix(predicate.name)
        predicate.objects.each do |object|
          if predicate.rdf_type?
            validate_prefix(object.name)
          else
            validate_object(object)
          end
        end
      end

      def validate_object(object)
        add_variable_name(object.name) unless object.is_a?(BlankNode) || object.is_a?(Subject)
        validate_prefix(object.value) if object.is_a?(URI)
      end

      def validate_resource_class(subject)
        return if subject.blank_node?
        
        add_error(%/Subject (#{subject.name}) has no rdf:type./) if subject.types.empty?
      end

      def validate_prefix(uri)
        return if /\A<.+>\z/ =~ uri.to_s

        if /\A(?<prefix>\w+)\:/ =~ uri.to_s
          return if @config.prefix.key?(prefix) || @undefined_prefixes.include?(prefix)

          add_undefined_prefixes(prefix)
          add_error(%/Prefix (#{prefix}) used but not defined in prefix.yaml file./)
        end
      end

      def validate_variable
        @num_variable.select { |k, v| v > 1 }.each do |variable_name, num_variable|
          add_error(%/Duplicate variable (#{variable_name}) in model.yaml file./)
        end
      end

      def add_error(error_message)
        @errors << error_message
      end

      def add_subject_name(subject_name)
        if @num_subject_name.key?(subject_name)
          @num_subject_name[subject_name] += 1
        else
          @num_subject_name[subject_name] = 1
        end
      end

      def add_undefined_prefixes(prefix)
        @undefined_prefixes << prefix unless @undefined_prefixes.include?(prefix)
      end

      def add_variable_name(variable_name)
        if @num_variable.key?(variable_name)
          @num_variable[variable_name] += 1
        else
          @num_variable[variable_name] = 1
        end
      end
    end
  end
end
