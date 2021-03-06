# JetCollins monkeypatches to add Collins integration

module Jetpants
  class Pool

    def alter_table(database, table, alter, dry_run=true, force=false, no_check_plan=false)
      database ||= app_schema
      error = false

      # get the version of pt-online-schema-change
      pt_osc_version = `pt-online-schema-change --version`.to_s.split(' ').last.chomp rescue '0.0.0'
      raise "pt-online-schema-change executable is not available on the host" unless $?.exitstatus == 1

      raise "not enough space to run alter table on #{table}" unless master.has_space_for_alter?(table, database)

      if Jetpants.plugin_enabled? 'jetpants_collins'
        raise "alter table already running on #{@name}" unless check_collins_for_alter
        update_collins_for_alter(database, table, alter)
      end

      max_threads = max_threads_running(30,1)
      max_threads = 50 unless max_threads > 50

      critical_threads_running = 2 * max_threads > 500 ? 2 * max_threads : 500

      # we need to escape single quotes from the alter query
      alter = alter.gsub("'"){"\\'"}

      master.with_online_schema_change_user('pt-osc', database) do |password|
        options = [
          "--nocheck-replication-filters",
          "--max-load='Threads_running:#{max_threads}'",
          "--critical-load='Threads_running:#{critical_threads_running}'",
          "--nodrop-old-table",
          "--nodrop-new-table",
          "--set-vars='wait_timeout=100000'",
          "--dry-run",
          "--print",
          "--alter '#{alter}'",
          "D=#{database},t=#{table},h=#{master.ip},u=pt-osc,p=#{password}"
        ]

        options.unshift("--nocheck-plan") if no_check_plan

        # the retries option is only needed for pt-online-schema-change version 2.1
        options.unshift("--retries=10") if pt_osc_version.to_f == 2.1

        command = "pt-online-schema-change #{options.join(' ')}"

        output
        output "---------------------------------------------------------------------------------------"
        output "#{command.green}"
        output "---------------------------------------------------------------------------------------"
        output

        IO.popen command do |io|
          io.each do |line|
            output line.gsub("\n", "")
          end
        end
        error = true if $?.to_i > 0

        unless dry_run || error
          continue = 'no'
          unless force
            continue = ask('Dry run complete would you like to continue?: (YES/no)')
          end

          if force || continue == 'YES'
            options.unshift "--no-check-alter"
            options.unshift "--execute"

            # --dry-run and --execute are mutually exclusive.
            options -= ["--dry-run"]

            command = "pt-online-schema-change #{options.join(' ')}"

            output
            output "---------------------------------------------------------------------------------------"
            output "#{command.red}"
            output "---------------------------------------------------------------------------------------"
            output

            IO.popen command do |io|
              io.each do |line|
                output line.gsub("\n","")
              end
            end
            error = true if $?.to_i > 0
          end
        end
      end

      ! error
    ensure
      if Jetpants.plugin_enabled? 'jetpants_collins'
        clean_up_collins_for_alter
      end
    end

    # drop old table after an alter, this is because
    # we do not drop the table after an alter
    def drop_old_alter_table(database, table)
      database ||= app_schema
      master.mysql_root_cmd("USE #{database}; DROP TABLE IF EXISTS _#{table}_old")
    end

  end
end
