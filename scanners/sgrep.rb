require "salus/scanners/base"
require "json"

# Report any matches to a list of semantic grep patterns provided by the config file.
# We sgrep, a grep like tool for doing AST pattern matching. See https://sgrep.dev for more info and documentation.
# Config file can provide:
#   - matches: Array[Hash]
#       pattern:     <string>  (required)      pattern to match against.
#       language:    <string>  (default 'python') language the pattern is written in.
#       forbidden:   <boolean> (default false) if true, a hit on this pattern will fail the test.
#       required:    <boolean> (default false) if true, the absense of this pattern is a failure.
#       message:     <string>  (default '')    custom message to display among failure.

module Salus::Scanners
  class Sgrep < Base
    def run
      # For each pattern, keep a running history of failures, errors, and hits
      # These will be reported on at the end.
      failure_messages = []
      errors = []
      all_hits = []

      Dir.chdir(@repository.path_to_repo) do
        @config["matches"]&.each do |match|
          # sgrep has the following behavior:
          #   always returns with status code 0 if able to parse
          #   ouputs a json object with a 'results' key
          #   this is either empty NO HITS
          #   or had hit objects with a simple schema

          # Set defaults.
          match["forbidden"] ||= false
          match["required"] ||= false
          match["message"] ||= ""
          match["language"] ||= "python"

          # build the sgrep command string
          command_string = [
            "sgrep",
            "-e",
            match["pattern"],
            "-lang",
            match["language"],
            "-r2c",
            ".",
          ]

          # run sgrep
          shell_return = run_shell(command_string)

          # check to make sure it's successful
          if shell_return.success?
            # parse the output
            data = JSON.parse(shell_return.stdout)
            hits = data["results"]
            if hits.empty?
              # If there were no hits, but the pattern was required add an error message.
              if match["required"]
                failure_messages << "Required pattern \"#{match["pattern"]}\" was not found " \
                "- #{match["message"]}"
              end
            else
              hits.each do |hit|
                if match["forbidden"]
                  failure_messages << "Forbidden pattern \"#{match["pattern"]}\" was found " \
                  "in #{hit["path"]}:#{hit["start"]["line"]}\n\t#{hit["extra"]["line"]}\n" \
                  "- #{match["message"]}"
                end
                all_hits << {
                  pattern: match["pattern"],
                  forbidden: match["forbidden"],
                  required: match["required"],
                  msg: match["message"],
                  hit: hit,
                }
              end
            end
          elsif [1, 2].include?(shell_return.status)
            # TODO (DrewDennison) add better error messaging here 
            errors << { status: shell_return.status, stderr: shell_return.stderr }
          else
            raise UnhandledExitStatusError,
                  "Unknown exit status #{shell_return.status} from sgrep.\n" \
                  "STDOUT: #{shell_return.stdout}\n" \
                  "STDERR: #{shell_return.stderr}"
          end
        end

        report_info(:hits, all_hits)
        errors.each { |error| report_error("Call to sgrep failed", error) }

        if failure_messages.empty?
          report_success
        else
          report_failure
          failure_messages.each { |message| log(message) }
        end
      end
    end

    def should_run?
      true # we will always run this on the provided folder TODO (DrewDennison)
    end
  end
end
