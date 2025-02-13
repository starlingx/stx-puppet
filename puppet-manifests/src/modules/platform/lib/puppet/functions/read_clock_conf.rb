Puppet::Functions.create_function(:'read_clock_conf') do
    dispatch :read_config do
      param 'String', :path
    end

    def read_config(path)
      config_hash = {}
      current_name = nil
      step = 0

      config_file = File.read(path)
      config_file.each_line do |line|
        if md = line.match(/^ifname \[(\S*)\]/)
          if !config_hash.has_key?(md[1])
            current_name = md[1]
            config_hash[current_name] = {
              'base_port' => nil,
              'ifname' => nil,
              'parameters' => {},
              'port_names' => [],
              'uuid' => nil
            }
            step = 1
          else
            next
          end
        elsif md = line.match(/^base_port \[(\S*)\]/)
          if step == 1
            config_hash[current_name]['base_port'] = md[1]
            step = 2
          else
            next
          end
        else md = line.match(/^(\S*) (\S*)$/)
          if step == 2 or step == 3
            config_hash[current_name]['parameters'][md[1]] = md[2]
            step = 3
          else
            next
          end
        end
      end

      return config_hash
    end
  end