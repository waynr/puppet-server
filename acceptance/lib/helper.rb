require 'beaker/dsl/install_utils'

module PuppetServerExtensions

  # Configuration code largely obtained from:
  # https://github.com/puppetlabs/classifier/blob/master/integration/helper.rb
  #
  def self.initialize_config(options)
    base_dir = File.join(File.dirname(__FILE__), '..')

    install_type = get_option_value(options[:puppetserver_install_type],
      [:git, :package], "install type", "PUPPETSERVER_INSTALL_TYPE", :package)

    install_mode =
        get_option_value(options[:puppetserver_install_mode],
                         [:install, :upgrade], "install mode",
                         "PUPPETSERVER_INSTALL_MODE", :install)

    puppetserver_version =
        get_option_value(options[:puppetserver_version],
                         nil, "Puppet Server Version",
                         "PUPPETSERVER_VERSION", nil)

    puppet_version = get_option_value(options[:puppet_version],
                         nil, "Puppet Version", "PUPPET_VERSION", nil) ||
                         get_puppet_version

    puppet_build_version = get_option_value(options[:puppet_build_version],
                         nil, "Puppet Development Build Version",
                         "PUPPET_BUILD_VERSION", "4d95e137cdd4678b882c37dc11fc1d1ad4f84837")

    @config = {
      :base_dir => base_dir,
      :puppetserver_install_type => install_type,
      :puppetserver_install_mode => install_mode,
      :puppetserver_version => puppetserver_version,
      :puppet_version => puppet_version,
      :puppet_build_version => puppet_build_version,
    }

    pp_config = PP.pp(@config, "")

    Beaker::Log.notify "Puppet Server Acceptance Configuration:\n\n#{pp_config}\n\n"
  end

  class << self
    attr_reader :config
  end

  # Return the configuration hash initialized by
  # PuppetServerExtensions.initialize_config
  #
  def test_config
    PuppetServerExtensions.config
  end

  def self.get_option_value(value, legal_values, description,
    env_var_name = nil, default_value = nil)

    # precedence is environment variable, option file, default value
    value = ((env_var_name && ENV[env_var_name]) || value || default_value)
    if value
      value = value.to_sym
    end

    unless legal_values.nil? or legal_values.include?(value)
      raise ArgumentError, "Unsupported #{description} '#{value}'"
    end

    value
  end

  def self.get_puppet_version
    puppet_submodule = "ruby/puppet"
    puppet_version = `git --work-tree=#{puppet_submodule} --git-dir=#{puppet_submodule}/.git describe | cut -d- -f1`
    case puppet_version
    when /(\d\.\d\.\d)\n/
      return $1
    else
      logger.warn("Failed to discern Puppet version using `git describe` on #{puppet_submodule}")
      return nil
    end
  end

  def puppetserver_initialize_ssl
    hostname = on(master, 'facter hostname').stdout.strip
    fqdn = on(master, 'facter fqdn').stdout.strip

    step "Clear SSL on all hosts"
    hosts.each do |host|
      ssldir = on(host, puppet('agent --configprint ssldir')).stdout.chomp
      on(host, "rm -rf '#{ssldir}'/*")
    end

    step "Server: Start Puppet Server"
      old_retries = master['master-start-curl-retries']
      master['master-start-curl-retries'] = 300
      with_puppet_running_on(master, "main" => { "autosign" => true, "dns_alt_names" => "puppet,#{hostname},#{fqdn}", "verbose" => true, "daemonize" => true }) do

        hosts.each do |host|
          step "Agents: Run agent --test first time to gen CSR"
          on host, puppet("agent --test --server #{master}"), :acceptable_exit_codes => [0]
        end

      end
      master['master-start-curl-retries'] = old_retries
  end

  def puppet_server_collect_data(host, relative_path)
    variant, version, _, _ = master['platform'].to_array

    # This is an ugly hack to accomodate the difficulty around getting systemd
    # to output the daemon's standard out to the same place that the init
    # scripts typically do.
    use_journalctl = false
    case variant
    when /^fedora$/
      if version.to_i >= 15
        use_journalctl = true
      end
    when /^(el|centos)$/
      if version.to_i >= 7
        use_journalctl = true
      end
    end

    destination = File.join("./log/latest/puppetserver/", relative_path)
    FileUtils.mkdir_p(destination)
    scp_from master, "/var/log/puppetserver/puppetserver.log", destination
    if use_journalctl
      puppetserver_daemon_log = on(master, "journalctl -u puppetserver").stdout.strip
      destination = File.join(destination, "puppetserver-daemon.log")
      File.open(destination, 'w') {|file| file.puts puppetserver_daemon_log }
    else
      scp_from master, "/var/log/puppetserver/puppetserver-daemon.log", destination
    end
  end

  def install_puppet_server (host, make_env={})
    case test_config[:puppetserver_install_type]
    when :package
      install_package host, 'puppetserver'
    when :git
      project_version = 'puppet-server-version='
      project_version += test_config[:puppetserver_version] ||
        `lein with-profile ci pprint :version | tail -n 1 | cut -d\\" -f2`
      install_from_ezbake host, 'puppetserver', project_version, make_env
    else
      abort("Invalid install type: " + test_config[:puppetserver_install_type])
    end
  end

  def get_rubylibdir host, config_key
    on(host, "ruby -rrbconfig -e \"puts Config::CONFIG['#{config_key}']\"").stdout.strip
  end

  def configure_puppet_server
    variant, version, _, _ = master['platform'].to_array

    case variant
    when /^fedora$/
      config_key = 'sitelibdir'
      if version.to_i >= 17
        config_key = 'vendorlibdir'
      end
    when /^(el|centos)$/
      config_key = 'sitelibdir'
      if version.to_i >= 7
        config_key = 'vendorlibdir'
      end
    when /^(debian|ubuntu)$/
      config_key = 'sitelibdir'
    else
      logger.warn("#{platform}: Unsupported platform for puppetserver.")
    end

    rubylibdir = get_rubylibdir master, config_key
    create_remote_file master, '/etc/puppetserver/conf.d/os-settings.conf', <<EOF
os-settings: {
    ruby-load-path: [#{rubylibdir}]
}
EOF
    on master, "chmod 0644 /etc/puppetserver/conf.d/os-settings.conf"

  end

  def puppet_apply_as_puppet_user
    # When puppet apply is run for the first time, certain directories are
    # created as the user owning the process. In order to avoid creating these
    # directories as root (making them inaccessible to the puppet user) we must
    # first run puppet apply as the puppet user whenever puppet is first
    # installed.
    manifest_path = master.tmpfile("puppetserver_manifest.pp")
    herp_path = master.tmpfile("herp")

    manifest_content = <<-EOS
    file { "herp":
      path => '#{herp_path}',
      ensure => 'present',
      content => 'derp',
    }
    EOS

    user = master.puppet('master')['user']
    create_remote_file(master, manifest_path, manifest_content)
    on master, "chown #{user}:#{user} #{manifest_path}"
    on master, "chown #{user}:#{user} #{herp_path}"

    on master, "su -s /bin/bash -c \"puppet apply #{manifest_path}\" #{user}"
  end

  def upgrade_package(host, name)
    variant, _, _, _ = master['platform'].to_array
    case variant
      when /^(fedora|centos|eos|el)$/
        on(host, "rm -f $(rpm --verify #{name} | cut -f 4)")
        on(host, "yum -y reinstall #{name}")
        on(host, "yum -y upgrade #{name}")
      when /^(ubuntu|debian|cumulus)$/
        on(host, "apt-get install -o Dpkg::Options::='--force-confnew' -y --force-yes #{name}")
      else
        raise "Package #{name} cannot be upgraded on #{host}"
    end
  end

  def get_defaults_var(host, varname)
    if master.is_pe?
      package_name = "pe-puppetserver"
    else
      package_name = "puppetserver"
    end

    variant, version, _, _ = master['platform'].to_array

    case variant
    when /^(fedora|el|centos)$/
      defaults_dir = "/etc/sysconfig/"
    when /^(debian|ubuntu)$/
      defaults_dir = "/etc/default/"
    else
      logger.warn("#{platform}: Unsupported platform for puppetserver.")
    end

    defaults_file = File.join(defaults_dir, package_name)

    on(host, "source #{defaults_file}; echo -n $#{varname}")
    stdout
  end
end

Beaker::TestCase.send(:include, PuppetServerExtensions)
