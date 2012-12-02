module Eye::Controller::Load

  include Eye::Dsl::Validate

  def load(filename = "")
    if filename.blank?
      return {:error => false, :empty => true}
    end

    unless File.exists?(filename)
      error "config file '#{filename}' not found!"
      return {:error => true, :message => "config file '#{filename}' not found!"}
    end

    cfg = Eye::Dsl.load(nil, filename)

    new_config = merge_configs(@current_config, cfg)
    validate(new_config)

    create_objects(new_config)

    @current_config = new_config

    GC.start

    {:error => false}

  rescue Eye::Dsl::Error, Exception, NoMethodError => ex
    error "Error loading config <#{filename}>:"
    error ex.message
    error ex.backtrace.join("\n")

    # filter backtrace for user output
    bt = (ex.backtrace || []).reject{|line| line.to_s =~ %r{eye/lib/eye} || line.to_s =~ %r{lib/celluloid}} 
    {:error => true, :message => ex.message, :backtrace => bt}
  end

private

  def merge_configs(old_config, new_config)
    old_config.merge(new_config)
  end

  # create objects as diff, from configs
  def create_objects(new_config)
    new_config.each do |app_name, app_cfg|
      update_or_create_application(app_name, app_cfg.clone)
    end
  end

  def update_or_create_application(app_name, app_config)
    @old_groups = {}
    @old_processes = {}

    app = @applications.detect{|c| c.name == app_name}

    if app
      app.groups.each do |group|
        @old_groups[group.name] = group
        group.processes.each do |proc|
          @old_processes[proc.name] = proc
        end
      end

      @applications.delete(app)

      debug "update app #{app_name}"
    else
      debug "create app #{app_name}"
    end

    app = Eye::Application.new(app_name, app_config, @logger)
    @applications << app

    new_groups = app_config.delete(:groups)
    new_groups.each do |group_name, group_cfg|
      group = update_or_create_group(group_name, group_cfg.clone)
      app.add_group(group)
    end

    # now, need to clear @old_groups, and @old_processes    
    @old_groups.each{|_, group| group.clear; group.send_command(:remove) }
    @old_processes.each{|_, process| process.send_command(:remove) if process.alive? }

    app
  end

  def update_or_create_group(group_name, group_config)
    group = if @old_groups[group_name]
      debug "update group #{group_name}"
      group = @old_groups.delete(group_name)
      group.update_config(group_config)
      group.clear
      group
    else
      debug "create group #{group_name}"
      Eye::Group.new(group_name, group_config, @logger)
    end

    processes = group_config.delete(:processes)
    processes.each do |process_name, process_cfg|
      process = update_or_create_process(process_name, process_cfg)
      group.add_process(process)
    end

    group
  end

  def update_or_create_process(process_name, process_cfg)
    if @old_processes[process_name]
      debug "update process #{process_name}"
      process = @old_processes.delete(process_name)
      process.update_config(process_cfg)
      process      
    else
      debug "create process #{process_name}"
      process = Eye::Process.new(process_cfg, @logger)      
      process.queue(:monitor)
      process
    end
  end

end