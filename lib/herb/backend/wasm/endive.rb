# frozen_string_literal: true
# typed: true

module Herb
  module Backend
    module Wasm
      module Endive
        RESULT_HEADER_SIZE = 8
        WASM_PATH = ENV.fetch(
          "HERB_WASM_PATH",
          File.expand_path("../../../../wasm/portable/build/herb.wasm", File.dirname(__FILE__))
        )

        java_import "run.endive.runtime.ImportValues" # steep:ignore NoMethod
        java_import "run.endive.runtime.Instance" # steep:ignore NoMethod
        java_import "run.endive.wasi.WasiOptions" # steep:ignore NoMethod
        java_import "run.endive.wasi.WasiPreview1" # steep:ignore NoMethod
        java_import "run.endive.wasm.Parser" # steep:ignore NoMethod

        class Runtime
          def initialize
            @wasi = WasiPreview1.builder.with_options(WasiOptions.builder.build).build
            imports = ImportValues.builder.with_functions(@wasi.to_host_functions.to_a).build
            @instance = Instance.builder(Endive.wasm_module).with_import_values(imports).build
            @memory = @instance.memory
            @mutex = Mutex.new
          end

          def close
            @instance.close
            @wasi.close
          end

          def string(name)
            @mutex.synchronize do
              result_pointer = function(name).apply[0].to_i
              unwrap(result_pointer)
            ensure
              result_free(result_pointer)
            end
          end

          def extract_html(source)
            call("herb_wasm_extract_html", source)
          end

          def extract_ruby(source, options)
            call("herb_wasm_extract_ruby", source, options)
          end

          def lex(source, options)
            call("herb_wasm_lex", source, options, encoding: Encoding::BINARY)
          end

          def diff(old_source, new_source, options)
            call("herb_wasm_diff", old_source, new_source, options, encoding: Encoding::BINARY)
          end

          def parse(source, options)
            call("herb_wasm_parse", source, options, encoding: Encoding::BINARY)
          end

          private

          def function(name)
            @instance.export(name)
          end

          def call(name, *inputs, encoding: Encoding::UTF_8)
            pointers = [] #: Array[Integer]
            result_pointer = 0

            @mutex.synchronize do
              inputs.each { |input| pointers << write(input) }
              result_pointer = invoke(name, inputs, pointers)
              unwrap(result_pointer, encoding: encoding)
            ensure
              result_free(result_pointer)
              pointers.each { |pointer| deallocate(pointer) }
            end
          end

          def invoke(name, inputs, pointers)
            arguments = inputs.each_with_index.flat_map do |input, index|
              [pointers.fetch(index), input.bytesize]
            end #: Array[Integer]

            function(name).apply(*arguments)[0].to_i
          end

          def allocate(size)
            pointer = function("herb_wasm_allocate").apply(size)[0].to_i
            raise NoMemoryError, "Herb WebAssembly allocation failed" if pointer.zero?

            pointer
          end

          def deallocate(pointer)
            function("herb_wasm_deallocate").apply(pointer) if pointer&.nonzero?
          end

          def result_free(pointer)
            function("herb_wasm_result_free").apply(pointer) if pointer&.nonzero?
          end

          def write(value)
            bytes = value.b.to_java_bytes # steep:ignore NoMethod
            pointer = allocate(bytes.length)
            @memory.write(pointer, bytes) unless bytes.empty?
            pointer
          end

          def unwrap(pointer, encoding: Encoding::UTF_8)
            raise "Herb WebAssembly returned no result" if pointer.zero?

            status = @memory.read_int(pointer)
            length = @memory.read_int(pointer + 4)
            raise "Herb WebAssembly returned an invalid result length" if length.negative?

            value = String.from_java_bytes(@memory.readBytes(pointer + RESULT_HEADER_SIZE, length)) # steep:ignore NoMethod
            value.force_encoding(encoding)

            raise value.to_s unless status.zero?

            value
          end
        end

        module_function

        def libherb_version
          runtime.string("herb_wasm_libherb_version")
        end

        def prism_version
          runtime.string("herb_wasm_prism_version")
        end

        def extract_html(source)
          runtime.extract_html(source)
        end

        def extract_ruby(source, options)
          runtime.extract_ruby(source, options)
        end

        def lex(source, options)
          runtime.lex(source, options)
        end

        def diff(old_source, new_source, options)
          runtime.diff(old_source, new_source, options)
        end

        def parse(source, options)
          runtime.parse(source, options)
        end

        def runtime
          @runtime ||= Runtime.new
        end

        def wasm_module
          @wasm_module ||= begin
            raise LoadError, "Herb WebAssembly module not found at #{WASM_PATH}" unless File.file?(WASM_PATH)

            Parser.parse(java.io.File.new(WASM_PATH)) # steep:ignore NoMethod
          end
        end
      end
    end
  end
end
